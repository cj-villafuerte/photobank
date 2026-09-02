import 'dart:convert';
import 'dart:io';

import 'package:convert/convert.dart';
import 'package:crypto/crypto.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';

/// What the sync loop reports back to the UI after each asset.
class SyncProgress {
  final int done;
  final int total;
  final int uploaded;
  final int skipped;
  final int failed;
  final String currentName;
  const SyncProgress(this.done, this.total, this.uploaded, this.skipped, this.failed, this.currentName);
}

class DeviceStats {
  final int totalOnDevice;
  final int backedUp;
  const DeviceStats(this.totalOnDevice, this.backedUp);
  int get pending => totalOnDevice - backedUp;
}

/// Backs up the camera roll and tracks which device assets are safe to delete.
///
/// Local record: a map of device asset id -> sha256 checksum, persisted in
/// SharedPreferences. "Safe to delete" additionally requires the server to
/// confirm it still has the checksum at the moment of deletion.
class SyncService {
  final PhotobankApi api;
  SharedPreferences? _prefs;
  Map<String, String> _synced = {}; // asset id -> checksum
  Set<String> _liveDone = {}; // asset ids whose live-photo video is confirmed on server
  bool cancelRequested = false;

  SyncService(this.api);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    final raw = _prefs!.getString('synced_v1');
    if (raw != null) {
      _synced = (jsonDecode(raw) as Map).cast<String, String>();
    }
    _liveDone = (_prefs!.getStringList('live_done_v1') ?? []).toSet();
  }

  Future<void> _save() async {
    await _prefs!.setString('synced_v1', jsonEncode(_synced));
    await _prefs!.setStringList('live_done_v1', _liveDone.toList());
  }

  Future<bool> requestPermission() async {
    final perm = await PhotoManager.requestPermissionExtend();
    return perm.isAuth || perm.hasAccess;
  }

  Future<List<AssetEntity>> _allAssets() async {
    final paths = await PhotoManager.getAssetPathList(
      type: RequestType.common, // images + videos
      onlyAll: true,
    );
    if (paths.isEmpty) return [];
    final all = paths.first;
    final count = await all.assetCountAsync;
    final assets = <AssetEntity>[];
    for (var i = 0; i < count; i += 500) {
      assets.addAll(await all.getAssetListRange(start: i, end: i + 500));
    }
    return assets;
  }

  Future<DeviceStats> stats() async {
    final assets = await _allAssets();
    final backedUp = assets.where((a) => _synced.containsKey(a.id)).length;
    return DeviceStats(assets.length, backedUp);
  }

  static Future<String> _sha256OfFile(File file) async {
    final output = AccumulatorSink<Digest>();
    final input = sha256.startChunkedConversion(output);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return output.events.single.toString();
  }

  /// Uploads everything not yet on the server. Yields progress per asset;
  /// [onFileProgress] fires with byte-level progress of the current upload.
  /// [oldestFirst] uploads the back catalog before recent shots.
  Stream<SyncProgress> sync({
    void Function(int sent, int total)? onFileProgress,
    bool oldestFirst = false,
  }) async* {
    cancelRequested = false;
    final assets = await _allAssets();
    final todo = assets.where((a) => !_synced.containsKey(a.id)).toList()
      ..sort((a, b) => oldestFirst
          ? a.createDateTime.compareTo(b.createDateTime)
          : b.createDateTime.compareTo(a.createDateTime));
    var done = 0, uploaded = 0, skipped = 0, failed = 0;

    for (final asset in todo) {
      if (cancelRequested) break;
      final name = await asset.titleAsync;
      yield SyncProgress(done, todo.length, uploaded, skipped, failed, name);
      try {
        final file = await asset.originFile;
        if (file == null) {
          failed++;
        } else {
          final checksum = await _sha256OfFile(file);
          final existing = await api.existingChecksums([checksum]);
          String? serverId;
          var serverHasLive = false;
          final detail = existing[checksum];
          if (detail != null) {
            skipped++;
            serverId = detail.assetId.isEmpty ? null : detail.assetId;
            serverHasLive = detail.hasLiveVideo;
          } else {
            final outcome = await api.upload(file, name, asset.createDateTime,
                onProgress: onFileProgress);
            outcome.isNew ? uploaded++ : skipped++;
            serverId = outcome.assetId;
          }
          // Live Photos: ship the ~3s video half too (iOS only)
          if (asset.isLivePhoto && serverId != null && !serverHasLive) {
            try {
              final live = await asset.originFileWithSubtype;
              if (live != null && live.path != file.path) {
                await api.uploadLiveVideo(serverId, live);
                _liveDone.add(asset.id);
              }
            } catch (_) {
              // still is safely uploaded; live half can retry next sync
            }
          } else if (asset.isLivePhoto && serverHasLive) {
            _liveDone.add(asset.id);
          }
          _synced[asset.id] = checksum;
          await _save();
        }
      } on ApiException catch (e) {
        if (e.status == 401) rethrow; // session died - surface to UI for re-login
        failed++;
      } catch (_) {
        failed++;
      }
      done++;
      yield SyncProgress(done, todo.length, uploaded, skipped, failed, name);
    }

    // backfill: photos synced before live-photo support got their video half
    if (!cancelRequested) {
      final candidates = assets
          .where((a) => a.isLivePhoto && _synced.containsKey(a.id) && !_liveDone.contains(a.id))
          .toList();
      if (candidates.isNotEmpty) {
        yield SyncProgress(done, todo.length, uploaded, skipped, failed,
            'Live Photo videos (${candidates.length})…');
        final byChecksum = {for (final a in candidates) _synced[a.id]!: a};
        final existing = await api.existingChecksums(byChecksum.keys.toList());
        for (final entry in byChecksum.entries) {
          if (cancelRequested) break;
          final detail = existing[entry.key];
          if (detail == null) continue;
          if (detail.hasLiveVideo || detail.assetId.isEmpty) {
            _liveDone.add(entry.value.id);
            continue;
          }
          try {
            final still = await entry.value.originFile;
            final live = await entry.value.originFileWithSubtype;
            if (live != null && live.path != still?.path) {
              await api.uploadLiveVideo(detail.assetId, live);
            }
            _liveDone.add(entry.value.id);
          } catch (_) {
            // retry next sync
          }
        }
        await _save();
      }
    }
  }

  /// Deletes from the DEVICE every asset whose checksum the server confirms
  /// having right now. Returns the number of photos removed from the phone.
  Future<int> freeUpSpace() async {
    final assets = await _allAssets();
    final candidates = assets.where((a) => _synced.containsKey(a.id)).toList();
    if (candidates.isEmpty) return 0;

    // re-verify against the server before deleting anything
    final checksums = candidates.map((a) => _synced[a.id]!).toSet().toList();
    final confirmed = await api.existingChecksums(checksums);
    final deletable = candidates.where((a) => confirmed.containsKey(_synced[a.id]!)).toList();
    if (deletable.isEmpty) return 0;

    final deletedIds = await PhotoManager.editor.deleteWithIds(
      deletable.map((a) => a.id).toList(),
    );
    for (final id in deletedIds) {
      _synced.remove(id);
    }
    await _save();
    return deletedIds.length;
  }

  Future<void> clearLocalState() async {
    _synced = {};
    await _save();
  }
}
