import 'dart:io';

import 'package:flutter/foundation.dart' show Uint8List, ValueListenable;
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

import 'sync_service.dart' show SyncService;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'albums_page.dart' show showAddToAlbumSheet;
import 'api.dart';
import 'theme.dart';

/// Grid thumbnail; shows a "processing" tile while the server has not
/// generated the thumbnail yet (fresh uploads) instead of a blank square.
Widget thumbTile(PhotobankApi api, RemoteAsset a) {
  if (a.thumbStatus != 'done') {
    return Container(
      color: PbColors.surface2,
      child: Icon(a.thumbStatus == 'failed' ? Icons.broken_image_outlined : Icons.hourglass_top,
          size: 18, color: PbColors.faint),
    );
  }
  return Image.network(
    api.thumbUrl(a.id),
    headers: api.authHeaders,
    cacheWidth: 360,
    fit: BoxFit.cover,
    errorBuilder: (_, _, _) => Container(
        color: PbColors.surface2,
        child: const Icon(Icons.broken_image_outlined, size: 18, color: PbColors.faint)),
  );
}

/// Browse everything stored on the server, month by month, and save
/// individual photos/videos back to this phone's camera roll.
class LibraryPage extends StatefulWidget {
  final PhotobankApi api;
  /// Bumped by the shell when the server library changed (a backup finished) or the
  /// tab is reopened after a while; the page re-reads without blanking.
  final ValueListenable<int>? refresh;
  const LibraryPage({super.key, required this.api, this.refresh});
  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<TimelineBucket>? _buckets;
  String? _error;
  final Map<String, List<RemoteAsset>> _loaded = {};
  String _sort = 'date'; // date | size_desc | size_asc
  bool _favorites = false;
  List<RemoteAsset> _sizeAssets = [];
  bool _sizeHasMore = true;
  bool _sizeLoading = false;
  Set<String> _collapsed = {}; // month buckets folded up in the date view

  // What the timeline shows: 'all' merges the server with the phone's not-yet-backed-up
  // photos, 'server' is the server only, 'phone' is the camera roll with a cloud on
  // everything already backed up.
  String _source = 'all';
  List<AssetEntity> _phone = [];
  Set<String> _synced = {};
  final Map<String, Future<Uint8List?>> _localThumbs = {};

  static const _pageSize = 200;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) {
        setState(() {
          _collapsed = (p.getStringList('collapsed_months') ?? []).toSet();
          _source = p.getString('library_source') ?? 'all';
        });
        _loadPhone();
      }
    });
    _load();
    widget.refresh?.addListener(_reload);
  }

  Future<void> _setSource(String s) async {
    setState(() => _source = s);
    final p = await SharedPreferences.getInstance();
    await p.setString('library_source', s);
    if (s != 'server') _loadPhone();
  }

  /// The camera roll + which of it is already on the server (from the sync records).
  Future<void> _loadPhone() async {
    if (_source == 'server') return;
    try {
      final perm = await PhotoManager.requestPermissionExtend();
      if (!(perm.isAuth || perm.hasAccess)) {
        if (mounted) setState(() => _phone = []);
        return;
      }
      final paths = await PhotoManager.getAssetPathList(type: RequestType.common, onlyAll: true);
      final list = <AssetEntity>[];
      if (paths.isNotEmpty) {
        final all = paths.first;
        final n = await all.assetCountAsync;
        for (var i = 0; i < n; i += 500) {
          list.addAll(await all.getAssetListRange(start: i, end: i + 500));
        }
      }
      final synced = await SyncService.syncedDeviceIds();
      if (mounted) {
        setState(() {
          _phone = list;
          _synced = synced;
        });
      }
    } catch (_) {
      // no photo access or plugin hiccup: the server side still shows
    }
  }

  Future<Uint8List?> _localThumb(AssetEntity a) =>
      _localThumbs.putIfAbsent(a.id, () => a.thumbnailDataWithSize(const ThumbnailSize(320, 320)));

  static String _monthKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

  /// Months to show, newest first, with the server count and the phone items for each.
  List<_MonthRow> _rows() {
    final serverCounts = <String, int>{
      if (_source != 'phone') for (final b in _buckets ?? <TimelineBucket>[]) b.bucket: b.count,
    };
    final phoneByMonth = <String, List<AssetEntity>>{};
    if (_source != 'server' && !_favorites) {
      for (final a in _phone) {
        if (_source == 'all' && _synced.contains(a.id)) continue; // shown as its server copy
        phoneByMonth.putIfAbsent(_monthKey(a.createDateTime), () => []).add(a);
      }
    }
    final keys = <String>{...serverCounts.keys, ...phoneByMonth.keys}.toList()
      ..sort((a, b) => b.compareTo(a));
    return [
      for (final k in keys) _MonthRow(k, serverCounts[k] ?? 0, phoneByMonth[k] ?? const []),
    ];
  }

  @override
  void dispose() {
    widget.refresh?.removeListener(_reload);
    super.dispose();
  }

  /// Re-read the server while keeping what's on screen (no spinner flash).
  Future<void> _reload() async {
    if (!mounted) return;
    _loadPhone(); // a backup just finished: phone items move over to the server side
    try {
      if (_sort == 'date') {
        final buckets =
            _favorites ? await widget.api.favoriteBuckets() : await widget.api.buckets();
        if (mounted) {
          setState(() {
            _buckets = buckets;
            _loaded.clear(); // month sections fetch again as they show
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _sizeAssets = [];
            _sizeHasMore = true;
          });
        }
        await _loadMoreBySize();
      }
    } catch (_) {
      // keep the current view; the next explicit load surfaces errors
    }
  }

  Future<void> _saveCollapsed() async {
    final p = await SharedPreferences.getInstance();
    await p.setStringList('collapsed_months', _collapsed.toList());
  }

  void _toggleCollapsed(String bucket) {
    setState(() {
      if (!_collapsed.remove(bucket)) _collapsed.add(bucket);
    });
    _saveCollapsed();
  }

  void _setAllCollapsed(bool collapsed) {
    setState(() {
      _collapsed = collapsed ? (_buckets ?? []).map((b) => b.bucket).toSet() : {};
    });
    _saveCollapsed();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _buckets = null;
      _loaded.clear();
      _sizeAssets = [];
      _sizeHasMore = true;
    });
    try {
      if (_sort == 'date') {
        final buckets =
            _favorites ? await widget.api.favoriteBuckets() : await widget.api.buckets();
        if (mounted) setState(() => _buckets = buckets);
      } else {
        await _loadMoreBySize();
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load library: $e');
    }
  }

  Future<void> _loadMoreBySize() async {
    if (_sizeLoading || !_sizeHasMore) return;
    setState(() => _sizeLoading = true);
    try {
      final page = await widget.api
          .listAssets(_sort, _sizeAssets.length, _pageSize, favorites: _favorites);
      if (mounted) {
        setState(() {
          _sizeAssets = [..._sizeAssets, ...page];
          _sizeHasMore = page.length == _pageSize;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load library: $e');
    } finally {
      if (mounted) setState(() => _sizeLoading = false);
    }
  }

  static String fmtBytes(int bytes) {
    if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  Future<List<RemoteAsset>> _bucketAssets(String bucket) async {
    final cached = _loaded[bucket];
    if (cached != null) return cached;
    final assets = _favorites
        ? await widget.api.favoriteBucketAssets(bucket)
        : await widget.api.bucketAssets(bucket);
    _loaded[bucket] = assets;
    return assets;
  }

  String _monthLabel(String bucket) {
    final parts = bucket.split('-');
    final date = DateTime(int.parse(parts[0]), int.parse(parts[1]));
    const months = ['January', 'February', 'March', 'April', 'May', 'June',
        'July', 'August', 'September', 'October', 'November', 'December'];
    return '${months[date.month - 1]} ${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    final sortBar = Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'date', label: Text('Date')),
                ButtonSegment(value: 'size_desc', label: Text('Largest')),
                ButtonSegment(value: 'size_asc', label: Text('Smallest')),
              ],
              selected: {_sort},
              onSelectionChanged: (sel) {
                setState(() => _sort = sel.first);
                _load();
              },
            ),
          ),
          if (_sort == 'date')
            IconButton(
              tooltip: _collapsed.isEmpty ? 'Collapse all months' : 'Expand all months',
              icon: Icon(_collapsed.isEmpty ? Icons.unfold_less : Icons.unfold_more),
              onPressed: () => _setAllCollapsed(_collapsed.isEmpty),
            ),
          IconButton(
            tooltip: _favorites ? 'Showing favorites' : 'Favorites only',
            icon: Icon(_favorites ? Icons.favorite : Icons.favorite_border,
                color: _favorites ? Colors.redAccent : null),
            onPressed: () {
              setState(() => _favorites = !_favorites);
              _load();
            },
          ),
        ],
      ),
    );

    if (_sort != 'date') {
      return Column(
        children: [
          sortBar,
          Expanded(
            child: _sizeAssets.isEmpty && _sizeLoading
                ? const Center(child: CircularProgressIndicator())
                : NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n.metrics.pixels > n.metrics.maxScrollExtent - 800) {
                        _loadMoreBySize();
                      }
                      return false;
                    },
                    child: GridView.builder(
                      padding: const EdgeInsets.all(4),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2),
                      itemCount: _sizeAssets.length,
                      itemBuilder: (context, i) {
                        final a = _sizeAssets[i];
                        return GestureDetector(
                          onTap: () => Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) => AssetViewer(
                                  api: widget.api, assets: _sizeAssets, initialIndex: i),
                            ),
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              thumbTile(widget.api, a),
                              Positioned(
                                right: 4,
                                bottom: 4,
                                child: Container(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.black54,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(fmtBytes(a.fileSize),
                                      style: const TextStyle(fontSize: 10)),
                                ),
                              ),
                              if (a.assetType == 'video')
                                const Positioned(
                                  right: 4, top: 4,
                                  child: Icon(Icons.play_circle_fill,
                                      size: 18, shadows: [Shadow(blurRadius: 4)]),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ],
      );
    }

    final buckets = _buckets;
    if (buckets == null && _source != 'phone') return const Center(child: CircularProgressIndicator());

    final sourceBar = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: SegmentedButton<String>(
        showSelectedIcon: false,
        segments: const [
          ButtonSegment(value: 'all', label: Text('All')),
          ButtonSegment(value: 'server', icon: Icon(Icons.cloud_done_outlined, size: 16), label: Text('Server')),
          ButtonSegment(value: 'phone', icon: Icon(Icons.smartphone, size: 16), label: Text('Phone')),
        ],
        selected: {_source},
        onSelectionChanged: (sel) => _setSource(sel.first),
      ),
    );

    final rows = _rows();
    if (rows.isEmpty) {
      return Column(
        children: [
          sortBar,
          sourceBar,
          Expanded(
            child: Center(
              child: Text(_source == 'phone'
                  ? 'No photos on this phone (or no photo access).'
                  : _source == 'server'
                      ? 'The server library is empty.'
                      : 'Nothing here yet - back up some photos or upload from the web.'),
            ),
          ),
        ],
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: rows.length + 2,
        itemBuilder: (context, i) {
          if (i == 0) return sortBar;
          if (i == 1) return sourceBar;
          final row = rows[i - 2];
          return _BucketSection(
            api: widget.api,
            bucketKey: row.key,
            label: _monthLabel(row.key),
            serverCount: row.serverCount,
            phoneItems: row.phoneItems,
            syncedIds: _synced,
            showCloudBadge: _source != 'server',
            loader: row.serverCount > 0 ? _bucketAssets : null,
            localThumb: _localThumb,
            collapsed: _collapsed.contains(row.key),
            onToggle: () => _toggleCollapsed(row.key),
          );
        },
      ),
    );
  }
}

class _MonthRow {
  final String key; // yyyy-MM
  final int serverCount;
  final List<AssetEntity> phoneItems;
  const _MonthRow(this.key, this.serverCount, this.phoneItems);
}

/// One tile in a merged month: either a server asset or a photo that is only on the phone.
class _GridItem {
  final RemoteAsset? remote;
  final AssetEntity? local;
  final DateTime when;
  const _GridItem.remote(RemoteAsset a)
      : remote = a,
        local = null,
        when = a.takenAt;
  _GridItem.local(AssetEntity a)
      : remote = null,
        local = a,
        when = a.createDateTime;
}

class _BucketSection extends StatelessWidget {
  final PhotobankApi api;
  final String bucketKey;
  final String label;
  final int serverCount;
  final List<AssetEntity> phoneItems;
  final Set<String> syncedIds;
  final bool showCloudBadge; // false in the server-only view (every tile would carry one)
  final Future<List<RemoteAsset>> Function(String)? loader; // null: nothing from the server
  final Future<Uint8List?> Function(AssetEntity) localThumb;
  final bool collapsed;
  final VoidCallback onToggle;
  const _BucketSection({
    required this.api,
    required this.bucketKey,
    required this.label,
    required this.serverCount,
    required this.phoneItems,
    required this.syncedIds,
    required this.showCloudBadge,
    required this.loader,
    required this.localThumb,
    required this.collapsed,
    required this.onToggle,
  });

  static const _badgeShadow = [Shadow(blurRadius: 4)];

  Widget _cloud(bool synced) => Positioned(
        right: 4,
        bottom: 4,
        child: Icon(synced ? Icons.cloud_done : Icons.smartphone,
            size: 15, color: Colors.white, shadows: _badgeShadow),
      );

  @override
  Widget build(BuildContext context) {
    final total = serverCount + phoneItems.length;
    final header = InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Text('$label  ·  $total', style: Theme.of(context).textTheme.titleMedium),
            ),
            Icon(collapsed ? Icons.expand_more : Icons.expand_less,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ),
      ),
    );
    if (collapsed) return header; // no fetch, no thumbnails for folded months
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        header,
        FutureBuilder<List<RemoteAsset>>(
          future: loader == null ? Future.value(const <RemoteAsset>[]) : loader!(bucketKey),
          builder: (context, snap) {
            if (snap.hasError) {
              return const Padding(
                padding: EdgeInsets.all(16),
                child: Text('Failed to load this month.'),
              );
            }
            final remote = snap.data;
            if (remote == null) {
              return const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              );
            }
            // one chronological grid: server copies and phone-only photos together
            final items = <_GridItem>[
              for (final a in remote) _GridItem.remote(a),
              for (final a in phoneItems) _GridItem.local(a),
            ]..sort((x, y) => y.when.compareTo(x.when));
            return GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 4, crossAxisSpacing: 2, mainAxisSpacing: 2),
              itemCount: items.length,
              itemBuilder: (context, i) {
                final item = items[i];
                final a = item.remote;
                if (a != null) {
                  return GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AssetViewer(api: api, assets: remote, initialIndex: remote.indexOf(a)),
                      ),
                    ),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        thumbTile(api, a),
                        if (a.assetType == 'video')
                          const Positioned(
                            right: 4, top: 4,
                            child: Icon(Icons.play_circle_fill, size: 18, shadows: _badgeShadow),
                          ),
                        if (a.hasLiveVideo)
                          const Positioned(
                            left: 4, top: 4,
                            child: Icon(Icons.motion_photos_on, size: 16, shadows: _badgeShadow),
                          ),
                        if (a.isFavorite)
                          const Positioned(
                            left: 4, bottom: 4,
                            child: Icon(Icons.favorite, size: 14, color: PbColors.accent, shadows: _badgeShadow),
                          ),
                        if (showCloudBadge) _cloud(true),
                      ],
                    ),
                  );
                }
                final local = item.local!;
                final synced = syncedIds.contains(local.id);
                return GestureDetector(
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => _LocalPhotoViewer(entity: local, synced: synced)),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      FutureBuilder<Uint8List?>(
                        future: localThumb(local),
                        builder: (context, s) => s.data == null
                            ? Container(color: PbColors.surface2)
                            : Image.memory(s.data!, fit: BoxFit.cover, gaplessPlayback: true),
                      ),
                      if (local.type == AssetType.video)
                        const Positioned(
                          right: 4, top: 4,
                          child: Icon(Icons.play_circle_fill, size: 18, shadows: _badgeShadow),
                        ),
                      _cloud(synced),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }
}

/// A photo that lives only on the phone (or is shown from the phone side): big preview
/// plus its backup state. Full playback and editing happen on the server copy.
class _LocalPhotoViewer extends StatelessWidget {
  final AssetEntity entity;
  final bool synced;
  const _LocalPhotoViewer({required this.entity, required this.synced});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        flexibleSpace: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x66000000), Color(0x00000000)],
            ),
          ),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(synced ? Icons.cloud_done : Icons.smartphone, size: 18, color: Colors.white),
            const SizedBox(width: 8),
            Text(synced ? 'Backed up' : 'Only on this phone',
                style: const TextStyle(color: Colors.white, fontSize: 15)),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: FutureBuilder<Uint8List?>(
                future: entity.thumbnailDataWithSize(const ThumbnailSize(2000, 2000)),
                builder: (context, s) => s.data == null
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : InteractiveViewer(maxScale: 5, child: Image.memory(s.data!, fit: BoxFit.contain)),
              ),
            ),
          ),
          if (!synced)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
              child: Text(
                'Not on the server yet. Run a backup from the Backup tab to send it there.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70),
              ),
            ),
        ],
      ),
    );
  }
}

class AssetViewer extends StatefulWidget {
  final PhotobankApi api;
  final List<RemoteAsset> assets;
  final int initialIndex;
  const AssetViewer({super.key, required this.api, required this.assets, required this.initialIndex});
  @override
  State<AssetViewer> createState() => _AssetViewerState();
}

class _AssetViewerState extends State<AssetViewer> {
  late final PageController _controller = PageController(initialPage: widget.initialIndex);
  late int _index = widget.initialIndex;
  bool _downloading = false;
  double _downloadPct = 0;
  VideoPlayerController? _video;
  bool _videoIsLive = false;
  final Map<String, bool> _favOverride = {}; // favorite toggles made in this viewer

  bool _isFav(RemoteAsset a) => _favOverride[a.id] ?? a.isFavorite;

  Future<void> _toggleFavorite(RemoteAsset a) async {
    try {
      final v = await widget.api.setFavorite(a.id, !_isFav(a));
      if (mounted) setState(() => _favOverride[a.id] = v);
    } catch (e) {
      _snack('Could not update favorite: $e');
    }
  }

  Future<void> _trashCurrent(RemoteAsset a) async {
    try {
      await widget.api.trashAsset(a.id);
      _snack('Moved to trash (restore from Settings > Trash)');
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _snack('Trash failed: $e');
    }
  }

  void _snack(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  void dispose() {
    _video?.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _stopVideo() {
    _video?.dispose();
    _video = null;
    _videoIsLive = false;
  }

  Future<void> _playUrl(String url, {required bool live}) async {
    _video?.dispose();
    final c = VideoPlayerController.networkUrl(Uri.parse(url),
        httpHeaders: widget.api.authHeaders);
    _video = c;
    _videoIsLive = live;
    try {
      await c.initialize();
      if (live) {
        c.addListener(() {
          // live photos play once, then fall back to the still
          if (c.value.isInitialized &&
              !c.value.isPlaying &&
              c.value.position >= c.value.duration &&
              mounted) {
            setState(_stopVideo);
          }
        });
      }
      await c.play();
      if (mounted) setState(() {});
    } catch (e) {
      if (mounted) {
        setState(_stopVideo);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Playback failed: $e')));
      }
    }
  }

  Future<void> _downloadCurrent() async {
    final asset = widget.assets[_index];
    setState(() {
      _downloading = true;
      _downloadPct = 0;
    });
    File? tmp;
    try {
      final filename = await widget.api.originalFilename(asset.id);
      final dir = await getTemporaryDirectory();
      tmp = File('${dir.path}/${asset.id}-$filename');
      await widget.api.downloadOriginal(asset.id, tmp, onProgress: (r, t) {
        if (t > 0 && mounted) setState(() => _downloadPct = r / t);
      });
      if (asset.assetType == 'video') {
        await PhotoManager.editor.saveVideo(tmp, title: filename);
      } else {
        await PhotoManager.editor.saveImageWithPath(tmp.path, title: filename);
      }
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Saved $filename to Photos')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Download failed: $e')));
      }
    } finally {
      try {
        tmp?.deleteSync();
      } catch (_) {}
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final asset = widget.assets[_index];
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true, // the photo runs under the bar; a soft scrim keeps icons legible
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        flexibleSpace: const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0x66000000), Color(0x00000000)],
            ),
          ),
        ),
        title: Text('${_index + 1} / ${widget.assets.length}', style: const TextStyle(color: Colors.white)),
        actions: [
          IconButton(
            icon: Icon(_isFav(asset) ? Icons.favorite : Icons.favorite_border,
                color: _isFav(asset) ? Colors.redAccent : null),
            tooltip: 'Favorite',
            onPressed: () => _toggleFavorite(asset),
          ),
          PopupMenuButton<String>(
            onSelected: (v) async {
              switch (v) {
                case 'album':
                  await showAddToAlbumSheet(context, widget.api, [asset.id]);
                case 'hide':
                  try {
                    await widget.api.hideAssets([asset.id]);
                    _snack('Hidden');
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    _snack('Hide failed: $e');
                  }
                case 'trash':
                  await _trashCurrent(asset);
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'album', child: ListTile(leading: Icon(Icons.photo_album_outlined), title: Text('Add to album'))),
              PopupMenuItem(value: 'hide', child: ListTile(leading: Icon(Icons.visibility_off), title: Text('Hide'))),
              PopupMenuItem(value: 'trash', child: ListTile(leading: Icon(Icons.delete_outline), title: Text('Move to trash'))),
            ],
          ),
          if (asset.hasLiveVideo)
            IconButton(
              icon: Icon(_videoIsLive && _video != null
                  ? Icons.motion_photos_pause
                  : Icons.motion_photos_on),
              tooltip: 'Play Live Photo',
              onPressed: () {
                if (_video != null && _videoIsLive) {
                  setState(_stopVideo);
                } else {
                  _playUrl(widget.api.liveVideoUrl(asset.id), live: true);
                }
              },
            ),
          if (_downloading)
            Padding(
              padding: const EdgeInsets.all(14),
              child: SizedBox(
                width: 22, height: 22,
                child: CircularProgressIndicator(
                    strokeWidth: 2, value: _downloadPct > 0 ? _downloadPct : null),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.download),
              tooltip: 'Save to Photos',
              onPressed: _downloadCurrent,
            ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.assets.length,
        onPageChanged: (i) => setState(() {
          _index = i;
          _stopVideo();
        }),
        itemBuilder: (context, i) {
          final a = widget.assets[i];
          final video = _video;
          final showingVideo = i == _index && video != null && video.value.isInitialized;
          return Center(
            child: showingVideo
                ? AspectRatio(
                    aspectRatio: video.value.aspectRatio,
                    child: GestureDetector(
                      onTap: () => setState(() =>
                          video.value.isPlaying ? video.pause() : video.play()),
                      child: VideoPlayer(video),
                    ),
                  )
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      InteractiveViewer(
                        maxScale: 5,
                        child: Image.network(
                          widget.api.previewUrl(a.id),
                          headers: widget.api.authHeaders,
                          fit: BoxFit.contain,
                          loadingBuilder: (_, child, progress) =>
                              progress == null ? child : const CircularProgressIndicator(),
                          errorBuilder: (_, _, _) => const Icon(Icons.broken_image, size: 48),
                        ),
                      ),
                      if (a.assetType == 'video')
                        IconButton(
                          iconSize: 72,
                          color: Colors.white70,
                          icon: const Icon(Icons.play_circle_outline),
                          onPressed: () =>
                              _playUrl(widget.api.originalUrl(a.id), live: false),
                        ),
                    ],
                  ),
          );
        },
      ),
    );
  }
}
