import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

const _mimeByExt = {
  'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif',
  'webp': 'image/webp', 'heic': 'image/heic', 'heif': 'image/heif', 'avif': 'image/avif',
  'bmp': 'image/bmp', 'tif': 'image/tiff', 'tiff': 'image/tiff',
  'mp4': 'video/mp4', 'mov': 'video/quicktime', 'm4v': 'video/x-m4v',
  'webm': 'video/webm', 'mkv': 'video/x-matroska', 'avi': 'video/x-msvideo',
  '3gp': 'video/3gpp',
};

MediaType? mediaTypeFor(String filename) {
  final dot = filename.lastIndexOf('.');
  if (dot < 0) return null;
  final mime = _mimeByExt[filename.substring(dot + 1).toLowerCase()];
  return mime == null ? null : MediaType.parse(mime);
}

/// MultipartRequest that reports how many bytes have been handed to the
/// HTTP client, so the UI can show per-file upload progress.
class _ProgressMultipartRequest extends http.MultipartRequest {
  final void Function(int sent, int total) onProgress;
  _ProgressMultipartRequest(super.method, super.url, {required this.onProgress});

  @override
  http.ByteStream finalize() {
    final total = contentLength;
    var sent = 0;
    final stream = super.finalize().transform<List<int>>(
      StreamTransformer.fromHandlers(handleData: (chunk, sink) {
        sent += chunk.length;
        onProgress(sent, total);
        sink.add(chunk);
      }),
    );
    return http.ByteStream(stream);
  }
}

class TimelineBucket {
  final String bucket; // "2026-09"
  final int count;
  const TimelineBucket(this.bucket, this.count);
}

class RemoteAsset {
  final String id;
  final String assetType; // image | video
  final DateTime takenAt;
  final bool isFavorite;
  final double? durationSec;
  final bool hasLiveVideo;
  final int fileSize;
  final int? width;
  final int? height;
  final String thumbStatus;
  const RemoteAsset(this.id, this.assetType, this.takenAt, this.isFavorite, this.durationSec,
      this.hasLiveVideo, this.fileSize, [this.width, this.height, this.thumbStatus = 'done']);

  factory RemoteAsset.fromJson(Map<String, dynamic> j) => RemoteAsset(
        j['id'] as String,
        j['asset_type'] as String,
        DateTime.parse(j['taken_at'] as String).toLocal(),
        j['is_favorite'] as bool? ?? false,
        (j['duration_sec'] as num?)?.toDouble(),
        j['has_live_video'] as bool? ?? false,
        (j['file_size'] as num?)?.toInt() ?? 0,
        (j['width'] as num?)?.toInt(),
        (j['height'] as num?)?.toInt(),
        j['thumb_status'] as String? ?? 'done',
      );
}

class TextMatch {
  final String word;
  final double x, y, w, h;
  const TextMatch(this.word, this.x, this.y, this.w, this.h);
}

class TextSearchResult {
  final RemoteAsset asset;
  final List<TextMatch> matches;
  const TextSearchResult(this.asset, this.matches);
}

class DailyStat {
  final String date;
  final int count;
  final int bytes;
  const DailyStat(this.date, this.count, this.bytes);
}

class Stats {
  final int totalCount, totalBytes, imageCount, videoCount;
  final List<DailyStat> daily;
  const Stats(this.totalCount, this.totalBytes, this.imageCount, this.videoCount, this.daily);
}

class DuplicateGroup {
  final List<RemoteAsset> assets;
  final int wastedBytes;
  const DuplicateGroup(this.assets, this.wastedBytes);
}

class Album {
  final String id;
  final String name;
  final String? coverAssetId;
  final int assetCount;
  const Album(this.id, this.name, this.coverAssetId, this.assetCount);
  factory Album.fromJson(Map<String, dynamic> j) => Album(
        j['id'] as String,
        j['name'] as String,
        j['cover_asset_id'] as String?,
        (j['asset_count'] as num?)?.toInt() ?? 0,
      );
}

class ExistsDetail {
  final String assetId;
  final bool hasLiveVideo;
  final String? checksum;
  const ExistsDetail(this.assetId, this.hasLiveVideo, {this.checksum});
}

class UploadOutcome {
  final bool isNew;
  final String? assetId;
  const UploadOutcome(this.isNew, this.assetId);
}

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  @override
  String toString() => 'ApiException($status): $message';
}

/// Served by /api/health when the server is the public demo: one shared account,
/// a read-only sample library, uploads removed after a few seconds.
class DemoInfo {
  final String email;
  final String password;
  final int uploadTtlSeconds;
  final int maxUploads;
  final int maxUploadMb;
  const DemoInfo(this.email, this.password, this.uploadTtlSeconds, this.maxUploads, this.maxUploadMb);
  factory DemoInfo.fromJson(Map<String, dynamic> j) => DemoInfo(
        j['email'] as String? ?? '',
        j['password'] as String? ?? '',
        (j['upload_ttl_seconds'] as num?)?.toInt() ?? 5,
        (j['max_uploads'] as num?)?.toInt() ?? 100,
        (j['max_upload_mb'] as num?)?.toInt() ?? 12,
      );
}

class PhotobankApi {
  String baseUrl; // e.g. http://192.168.1.23:8000
  String? token;
  DemoInfo? demo; // set by checkHealth(); non-null on the public demo server

  PhotobankApi({required this.baseUrl, this.token});

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  Future<void> checkHealth() async {
    final res = await http.get(_u('/api/health')).timeout(const Duration(seconds: 8));
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'Server responded but health check failed');
    }
    try {
      final d = (jsonDecode(res.body) as Map<String, dynamic>)['demo'];
      demo = d is Map<String, dynamic> ? DemoInfo.fromJson(d) : null;
    } catch (_) {
      demo = null;
    }
  }

  /// Exchanges credentials for a long-lived bearer token.
  Future<String> login(String email, String password) async {
    final res = await http.post(
      _u('/api/auth/token'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password}),
    );
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, _detail(res));
    }
    token = jsonDecode(res.body)['token'] as String;
    return token!;
  }

  Future<Map<String, dynamic>> me() async {
    final res = await http.get(_u('/api/auth/me'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return jsonDecode(res.body) as Map<String, dynamic>;
  }

  /// For each checksum the server already has: its asset id + live-video state.
  Future<Map<String, ExistsDetail>> existingChecksums(List<String> checksums) async {
    final existing = <String, ExistsDetail>{};
    // server caps the list at 2000 per request
    for (var i = 0; i < checksums.length; i += 1000) {
      final batch = checksums.sublist(i, i + 1000 > checksums.length ? checksums.length : i + 1000);
      final res = await http.post(
        _u('/api/assets/exists'),
        headers: _headers,
        body: jsonEncode({'checksums': batch}),
      );
      if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      for (final d in (body['details'] as List? ?? [])) {
        existing[d['checksum'] as String] =
            ExistsDetail(d['asset_id'] as String, d['has_live_video'] as bool? ?? false);
      }
      // older servers only send 'existing' checksums without details
      for (final c in (body['existing'] as List? ?? []).cast<String>()) {
        existing.putIfAbsent(c, () => const ExistsDetail('', true));
      }
    }
    return existing;
  }

  /// Cheap reconciliation: which of these device items already exist on the
  /// server (matched by name + capture time + dimensions, no hashing).
  Future<Map<String, ExistsDetail>> matchAssets(List<Map<String, dynamic>> items) async {
    final out = <String, ExistsDetail>{};
    for (var i = 0; i < items.length; i += 500) {
      final batch = items.sublist(i, i + 500 > items.length ? items.length : i + 500);
      final res = await http.post(_u('/api/assets/match'),
          headers: _headers, body: jsonEncode({'items': batch}));
      if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
      for (final m in (jsonDecode(res.body) as Map<String, dynamic>)['matches'] as List) {
        out[m['key'] as String] = ExistsDetail(
            m['asset_id'] as String, m['has_live_video'] as bool? ?? false,
            checksum: m['checksum'] as String);
      }
    }
    return out;
  }

  /// Uploads one file; reports whether it was newly stored and its server id.
  Future<UploadOutcome> upload(
    File file,
    String filename,
    DateTime? takenAt, {
    void Function(int sent, int total)? onProgress,
  }) async {
    final req = onProgress != null
        ? _ProgressMultipartRequest('POST', _u('/api/assets'), onProgress: onProgress)
        : http.MultipartRequest('POST', _u('/api/assets'));
    if (token != null) req.headers['Authorization'] = 'Bearer $token';
    req.files.add(await http.MultipartFile.fromPath('file', file.path,
        filename: filename, contentType: mediaTypeFor(filename)));
    if (takenAt != null) {
      req.fields['last_modified_ms'] = takenAt.millisecondsSinceEpoch.toString();
    }
    final streamed = await req.send().timeout(const Duration(minutes: 10));
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode == 201 || res.statusCode == 200) {
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      return UploadOutcome(res.statusCode == 201, body['asset_id'] as String?);
    }
    throw ApiException(res.statusCode, _detail(res));
  }

  /// Attaches the video half of a Live Photo to an already-uploaded still.
  Future<void> uploadLiveVideo(String assetId, File file) async {
    final req = http.MultipartRequest('POST', _u('/api/assets/$assetId/live-video'));
    req.headers.addAll(authHeaders);
    req.files.add(await http.MultipartFile.fromPath('file', file.path,
        filename: 'live.mov', contentType: MediaType('video', 'quicktime')));
    final streamed = await req.send().timeout(const Duration(minutes: 10));
    final res = await http.Response.fromStream(streamed);
    if (res.statusCode != 200 && res.statusCode != 201) {
      throw ApiException(res.statusCode, _detail(res));
    }
  }

  String liveVideoUrl(String id) => '$baseUrl/api/assets/$id/live-video';
  String originalUrl(String id) => '$baseUrl/api/assets/$id/original';

  Future<List<TextSearchResult>> searchText(String q) async {
    final res = await http.get(
        _u('/api/search/text?q=${Uri.encodeQueryComponent(q)}'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return (jsonDecode(res.body) as List).map((r) {
      final m = r as Map<String, dynamic>;
      return TextSearchResult(
        RemoteAsset.fromJson(m['asset'] as Map<String, dynamic>),
        (m['matches'] as List)
            .map((t) => TextMatch(t['word'] as String, (t['x'] as num).toDouble(),
                (t['y'] as num).toDouble(), (t['w'] as num).toDouble(), (t['h'] as num).toDouble()))
            .toList(),
      );
    }).toList();
  }

  Future<Stats> stats(int days) async {
    final res = await http.get(_u('/api/stats?days=$days'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return Stats(
      j['total_count'] as int,
      (j['total_bytes'] as num).toInt(),
      j['image_count'] as int,
      j['video_count'] as int,
      (j['daily'] as List)
          .map((d) => DailyStat(d['date'] as String, d['count'] as int, (d['bytes'] as num).toInt()))
          .toList(),
    );
  }

  Future<List<DuplicateGroup>> duplicates() async {
    final res = await http.get(_u('/api/duplicates'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return (jsonDecode(res.body) as List).map((g) {
      final m = g as Map<String, dynamic>;
      return DuplicateGroup(
        (m['assets'] as List).map((a) => RemoteAsset.fromJson(a as Map<String, dynamic>)).toList(),
        (m['wasted_bytes'] as num).toInt(),
      );
    }).toList();
  }

  Future<void> trashAsset(String id) async {
    final res = await http.delete(_u('/api/assets/$id'), headers: _headers);
    if (res.statusCode != 204) throw ApiException(res.statusCode, _detail(res));
  }

  Future<bool> setFavorite(String id, bool value) async {
    final res = await http.patch(_u('/api/assets/$id'),
        headers: _headers, body: jsonEncode({'is_favorite': value}));
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return (jsonDecode(res.body) as Map<String, dynamic>)['is_favorite'] as bool;
  }

  Future<List<TimelineBucket>> favoriteBuckets() async {
    final res = await http.get(_u('/api/timeline/buckets?favorites=true'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return (jsonDecode(res.body) as List)
        .map((b) => TimelineBucket(b['bucket'] as String, b['count'] as int))
        .toList();
  }

  Future<List<RemoteAsset>> favoriteBucketAssets(String bucket) async {
    final res =
        await http.get(_u('/api/timeline/bucket/$bucket?favorites=true'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return (jsonDecode(res.body) as List)
        .map((j) => RemoteAsset.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  // ---- albums ----
  Future<List<Album>> albums() async {
    final res = await http.get(_u('/api/albums'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return (jsonDecode(res.body) as List)
        .map((a) => Album.fromJson(a as Map<String, dynamic>))
        .toList();
  }

  Future<Album> createAlbum(String name) async {
    final res = await http.post(_u('/api/albums'),
        headers: _headers, body: jsonEncode({'name': name}));
    if (res.statusCode != 201) throw ApiException(res.statusCode, _detail(res));
    return Album.fromJson(jsonDecode(res.body) as Map<String, dynamic>);
  }

  Future<(Album, List<RemoteAsset>)> album(String id) async {
    final res = await http.get(_u('/api/albums/$id'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return (
      Album.fromJson(j),
      (j['assets'] as List).map((a) => RemoteAsset.fromJson(a as Map<String, dynamic>)).toList(),
    );
  }

  Future<void> renameAlbum(String id, String name) async {
    final res = await http.patch(_u('/api/albums/$id'),
        headers: _headers, body: jsonEncode({'name': name}));
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
  }

  Future<void> deleteAlbum(String id) async {
    final res = await http.delete(_u('/api/albums/$id'), headers: _headers);
    if (res.statusCode != 204) throw ApiException(res.statusCode, _detail(res));
  }

  Future<void> addToAlbum(String albumId, List<String> assetIds) async {
    final res = await http.put(_u('/api/albums/$albumId/assets'),
        headers: _headers, body: jsonEncode({'asset_ids': assetIds}));
    if (res.statusCode != 204) throw ApiException(res.statusCode, _detail(res));
  }

  Future<void> removeFromAlbum(String albumId, List<String> assetIds) async {
    final req = http.Request('DELETE', _u('/api/albums/$albumId/assets'))
      ..headers.addAll(_headers)
      ..body = jsonEncode({'asset_ids': assetIds});
    final res = await http.Response.fromStream(await req.send());
    if (res.statusCode != 204) throw ApiException(res.statusCode, _detail(res));
  }

  // ---- trash ----
  Future<List<RemoteAsset>> trash() async {
    final res = await http.get(_u('/api/trash'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return (jsonDecode(res.body) as List)
        .map((j) => RemoteAsset.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<void> restoreFromTrash(List<String> ids) async {
    final res = await http.post(_u('/api/trash/restore'),
        headers: _headers, body: jsonEncode({'asset_ids': ids}));
    if (res.statusCode != 204) throw ApiException(res.statusCode, _detail(res));
  }

  Future<void> permanentDelete(String id) async {
    final res = await http.delete(_u('/api/assets/$id/permanent'), headers: _headers);
    if (res.statusCode != 204) throw ApiException(res.statusCode, _detail(res));
  }

  Future<void> emptyTrash() async {
    final res = await http.post(_u('/api/trash/empty'), headers: _headers);
    if (res.statusCode != 204) throw ApiException(res.statusCode, _detail(res));
  }

  Future<void> hideAssets(List<String> ids) async {
    final res = await http.post(_u('/api/assets/hide'),
        headers: _headers, body: jsonEncode({'asset_ids': ids}));
    if (res.statusCode != 204) throw ApiException(res.statusCode, _detail(res));
  }

  Future<void> unhideAssets(List<String> ids) async {
    final res = await http.post(_u('/api/assets/unhide'),
        headers: _headers, body: jsonEncode({'asset_ids': ids}));
    if (res.statusCode != 204) throw ApiException(res.statusCode, _detail(res));
  }

  Future<List<RemoteAsset>> hiddenAssets() async {
    final res = await http.get(_u('/api/hidden'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return (jsonDecode(res.body) as List)
        .map((j) => RemoteAsset.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Map<String, String> get authHeaders =>
      {if (token != null) 'Authorization': 'Bearer $token'};

  String thumbUrl(String id) => '$baseUrl/api/assets/$id/thumbnail';
  String previewUrl(String id) => '$baseUrl/api/assets/$id/preview';

  Future<List<TimelineBucket>> buckets() async {
    final res = await http.get(_u('/api/timeline/buckets'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return (jsonDecode(res.body) as List)
        .map((b) => TimelineBucket(b['bucket'] as String, b['count'] as int))
        .toList();
  }

  Future<List<RemoteAsset>> listAssets(String sort, int offset, int limit,
      {bool favorites = false}) async {
    final res = await http.get(
        _u('/api/assets/list?sort=$sort&offset=$offset&limit=$limit&favorites=$favorites'),
        headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return (jsonDecode(res.body) as List)
        .map((j) => RemoteAsset.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<List<RemoteAsset>> bucketAssets(String bucket) async {
    final res = await http.get(_u('/api/timeline/bucket/$bucket'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return (jsonDecode(res.body) as List)
        .map((j) => RemoteAsset.fromJson(j as Map<String, dynamic>))
        .toList();
  }

  Future<String> originalFilename(String id) async {
    final res = await http.get(_u('/api/assets/$id'), headers: _headers);
    if (res.statusCode != 200) throw ApiException(res.statusCode, _detail(res));
    return (jsonDecode(res.body) as Map<String, dynamic>)['original_filename'] as String;
  }

  /// Streams the original file to [dest] without buffering it in memory.
  Future<void> downloadOriginal(String id, File dest,
      {void Function(int received, int total)? onProgress}) async {
    final req = http.Request('GET', _u('/api/assets/$id/original'));
    req.headers.addAll(authHeaders);
    final res = await http.Client().send(req);
    if (res.statusCode != 200) {
      throw ApiException(res.statusCode, 'Download failed');
    }
    final total = res.contentLength ?? 0;
    var received = 0;
    final sink = dest.openWrite();
    try {
      await for (final chunk in res.stream) {
        received += chunk.length;
        sink.add(chunk);
        onProgress?.call(received, total);
      }
    } finally {
      await sink.close();
    }
  }

  String _detail(http.Response res) {
    try {
      final body = jsonDecode(res.body);
      if (body is Map && body['detail'] is String) return body['detail'] as String;
    } catch (_) {}
    return res.reasonPhrase ?? 'HTTP ${res.statusCode}';
  }
}
