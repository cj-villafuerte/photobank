import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show Uint8List, ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show MethodCall;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

import 'albums_page.dart' show showAddToAlbumSheet;
import 'api.dart';
import 'sync_service.dart' show SyncService;
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
    gaplessPlayback: true,
    // fade in instead of popping; cached thumbnails render synchronously with no fade
    frameBuilder: (context, child, frame, wasSync) => wasSync
        ? child
        : AnimatedOpacity(
            opacity: frame == null ? 0 : 1,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
            child: child,
          ),
    errorBuilder: (_, _, _) => Container(
        color: PbColors.surface2,
        child: const Icon(Icons.broken_image_outlined, size: 18, color: PbColors.faint)),
  );
}

/// Opening a photo: a quick fade reads as "zooming in on what I tapped" far better than
/// the platform's page slide, and it never competes with the image still loading.
Route<T> viewerRoute<T>(Widget page) => PageRouteBuilder<T>(
      opaque: true,
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (_, _, _) => page,
      transitionsBuilder: (_, animation, _, child) => FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      ),
    );

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

class _LibraryPageState extends State<LibraryPage> with WidgetsBindingObserver {
  List<TimelineBucket>? _buckets;
  // the camera roll changes under us (a photo just taken, one deleted): re-read it,
  // coalescing the burst of notifications a single capture produces
  Timer? _phoneDebounce;
  String? _error;
  final Map<String, List<RemoteAsset>> _loaded = {};
  String _sort = 'date'; // date | size_desc | size_asc
  bool _favorites = false;
  List<RemoteAsset> _sizeAssets = [];
  bool _sizeHasMore = true;
  bool _sizeLoading = false;
  Set<String> _collapsed = {}; // month buckets folded up in the date view

  // What the timeline shows: 'all' merges the server with the photos that are only on
  // this phone, 'server' is the server only, 'phone' is only what is not backed up yet.
  // A backed-up photo is always its server copy (favorites, albums, playback), whatever
  // the filter - the filter changes which photos show, never what a photo can do.
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
    WidgetsBinding.instance.addObserver(this);
    PhotoManager.addChangeCallback(_onPhotoLibraryChange);
    PhotoManager.startChangeNotify();
  }

  void _onPhotoLibraryChange(MethodCall call) {
    _phoneDebounce?.cancel();
    _phoneDebounce = Timer(const Duration(milliseconds: 600), _loadPhone);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // back from the Camera app (or anywhere): whatever was taken meanwhile shows up
    if (state == AppLifecycleState.resumed) _loadPhone();
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
        if (_synced.contains(a.id)) continue; // backed up: shown as its server copy
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
    _phoneDebounce?.cancel();
    PhotoManager.removeChangeCallback(_onPhotoLibraryChange);
    PhotoManager.stopChangeNotify();
    WidgetsBinding.instance.removeObserver(this);
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

  // Months load on demand as their header scrolls near the viewport (slivers build
  // lazily), so a 500-photo month costs nothing until you reach it.
  final Set<String> _loadingMonths = {};
  final Set<String> _failedMonths = {};

  void _ensureMonth(String bucket) {
    if (_loaded.containsKey(bucket) || _loadingMonths.contains(bucket) || _failedMonths.contains(bucket)) return;
    _loadingMonths.add(bucket);
    () async {
      try {
        await _bucketAssets(bucket);
      } catch (_) {
        _failedMonths.add(bucket);
      } finally {
        _loadingMonths.remove(bucket);
        if (mounted) setState(() {});
      }
    }();
  }

  Widget _cloudBadge(bool synced) => Positioned(
        right: 4,
        bottom: 4,
        child: Icon(synced ? Icons.cloud_done : Icons.smartphone,
            size: 15, color: Colors.white, shadows: const [Shadow(blurRadius: 4)]),
      );

  Widget _tile(BuildContext context, _GridItem item, List<RemoteAsset> remote) {
    const shadow = [Shadow(blurRadius: 4)];
    final a = item.remote;
    if (a != null) {
      return GestureDetector(
        onTap: () => Navigator.push(
          context,
          viewerRoute(AssetViewer(api: widget.api, assets: remote, initialIndex: remote.indexOf(a))),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            thumbTile(widget.api, a),
            if (a.assetType == 'video')
              const Positioned(right: 4, top: 4, child: Icon(Icons.play_circle_fill, size: 18, shadows: shadow)),
            if (a.hasLiveVideo)
              const Positioned(left: 4, top: 4, child: Icon(Icons.motion_photos_on, size: 16, shadows: shadow)),
            if (a.isFavorite)
              const Positioned(left: 4, bottom: 4, child: Icon(Icons.favorite, size: 14, color: PbColors.accent, shadows: shadow)),
            if (_source != 'server') _cloudBadge(true),
          ],
        ),
      );
    }
    final local = item.local!;
    final synced = _synced.contains(local.id);
    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        viewerRoute(_LocalPhotoViewer(
          api: widget.api,
          entity: local,
          synced: synced,
          onBackedUp: () {
            _loadPhone(); // the tile moves to the server side
            _reload();
          },
        )),
      ),
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<Uint8List?>(
            future: _localThumb(local),
            builder: (context, s) => s.data == null
                ? Container(color: PbColors.surface2)
                : Image.memory(s.data!, fit: BoxFit.cover, gaplessPlayback: true),
          ),
          if (local.type == AssetType.video)
            const Positioned(right: 4, top: 4, child: Icon(Icons.play_circle_fill, size: 18, shadows: shadow)),
          _cloudBadge(synced),
        ],
      ),
    );
  }

  /// The month's photos as a lazy sliver grid (or its loading / failed state).
  Widget _monthSliver(_MonthRow row) {
    final needsServer = row.serverCount > 0;
    if (needsServer && !_loaded.containsKey(row.key)) {
      if (_failedMonths.contains(row.key)) {
        return SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Row(
              children: [
                const Text('Failed to load this month.'),
                TextButton(
                  onPressed: () => setState(() => _failedMonths.remove(row.key)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        );
      }
      _ensureMonth(row.key);
      return const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
      );
    }
    final remote = needsServer ? _loaded[row.key]! : const <RemoteAsset>[];
    final items = <_GridItem>[
      for (final a in remote) _GridItem.remote(a),
      for (final a in row.phoneItems) _GridItem.local(a),
    ]..sort((x, y) => y.when.compareTo(x.when));
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      sliver: SliverGrid.builder(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4, crossAxisSpacing: 2, mainAxisSpacing: 2),
        itemCount: items.length,
        itemBuilder: (context, i) => _tile(context, items[i], remote),
      ),
    );
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
    // One quiet row: where the photos come from (the everyday choice) on the left; sort,
    // favorites and folding behind a single "view options" menu on the right.
    final controls = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
      child: Row(
        children: [
          Expanded(
            child: _sort == 'date'
                ? SegmentedButton<String>(
                    showSelectedIcon: false,
                    style: const ButtonStyle(visualDensity: VisualDensity.compact),
                    segments: const [
                      // text only: with icons "Phone only" wraps onto two lines on a 6.7" phone
                      ButtonSegment(value: 'all', label: Text('All')),
                      ButtonSegment(value: 'server', label: Text('Server')),
                      ButtonSegment(value: 'phone', label: Text('Phone only')),
                    ],
                    selected: {_source},
                    onSelectionChanged: (sel) => _setSource(sel.first),
                  )
                : Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _sort == 'size_desc' ? 'LARGEST FIRST  ·  SERVER' : 'SMALLEST FIRST  ·  SERVER',
                      style: pbMono(size: 10),
                    ),
                  ),
          ),
          if (_favorites)
            const Padding(
              padding: EdgeInsets.only(left: 6),
              child: Icon(Icons.favorite, size: 16, color: PbColors.accent),
            ),
          PopupMenuButton<String>(
            tooltip: 'View options',
            icon: const Icon(Icons.tune),
            onSelected: (v) {
              switch (v) {
                case 'date':
                case 'size_desc':
                case 'size_asc':
                  setState(() => _sort = v);
                  _load();
                case 'favorites':
                  setState(() => _favorites = !_favorites);
                  _load();
                case 'fold':
                  _setAllCollapsed(_collapsed.isEmpty);
              }
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(value: 'date', checked: _sort == 'date', child: const Text('By date')),
              CheckedPopupMenuItem(value: 'size_desc', checked: _sort == 'size_desc', child: const Text('Largest first')),
              CheckedPopupMenuItem(value: 'size_asc', checked: _sort == 'size_asc', child: const Text('Smallest first')),
              const PopupMenuDivider(),
              CheckedPopupMenuItem(value: 'favorites', checked: _favorites, child: const Text('Favorites only')),
              if (_sort == 'date')
                PopupMenuItem(value: 'fold', child: Text(_collapsed.isEmpty ? 'Collapse all months' : 'Expand all months')),
            ],
          ),
        ],
      ),
    );

    if (_sort != 'date') {
      return Column(
        children: [
          controls,
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
                            viewerRoute(AssetViewer(api: widget.api, assets: _sizeAssets, initialIndex: i)),
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

    final rows = _rows();
    if (rows.isEmpty) {
      return Column(
        children: [
          controls,
          Expanded(
            child: Center(
              child: Text(_source == 'phone'
                  ? 'Nothing is only on this phone - everything is backed up (or the app has no photo access).'
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
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: controls),
          for (final row in rows) ...[
            SliverToBoxAdapter(
              child: _MonthHeader(
                label: _monthLabel(row.key),
                count: row.serverCount + row.phoneItems.length,
                collapsed: _collapsed.contains(row.key),
                onToggle: () => _toggleCollapsed(row.key),
              ),
            ),
            if (!_collapsed.contains(row.key)) _monthSliver(row),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

class _MonthHeader extends StatelessWidget {
  final String label;
  final int count;
  final bool collapsed;
  final VoidCallback onToggle;
  const _MonthHeader({required this.label, required this.count, required this.collapsed, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
        child: Row(
          children: [
            Expanded(child: Text('$label  ·  $count', style: Theme.of(context).textTheme.titleMedium)),
            Icon(collapsed ? Icons.expand_more : Icons.expand_less,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
          ],
        ),
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
  _GridItem.remote(RemoteAsset a)
      : remote = a,
        local = null,
        when = a.takenAt;
  _GridItem.local(AssetEntity a)
      : remote = null,
        local = a,
        when = a.createDateTime;
}

/// A photo that lives only on the phone (or is shown from the phone side): big preview,
/// its backup state, and a one-tap backup. Favorites, albums and playback belong to the
/// server copy, so they appear once it is backed up.
class _LocalPhotoViewer extends StatefulWidget {
  final PhotobankApi api;
  final AssetEntity entity;
  final bool synced;
  final VoidCallback? onBackedUp;
  const _LocalPhotoViewer({required this.api, required this.entity, required this.synced, this.onBackedUp});

  @override
  State<_LocalPhotoViewer> createState() => _LocalPhotoViewerState();
}

class _LocalPhotoViewerState extends State<_LocalPhotoViewer> {
  late bool _synced = widget.synced;
  bool _busy = false;
  double? _pct;
  String? _error;

  Future<void> _backUp() async {
    setState(() {
      _busy = true;
      _pct = null;
      _error = null;
    });
    try {
      final service = SyncService(widget.api);
      await service.init();
      final serverId = await service.backUpOne(widget.entity, onProgress: (sent, total) {
        if (total > 0 && mounted) setState(() => _pct = sent / total);
      });
      if (!mounted) return;
      if (serverId == null) {
        setState(() => _error = 'Could not read this photo from the phone (still downloading from iCloud?).');
        return;
      }
      setState(() => _synced = true);
      widget.onBackedUp?.call();
      // it is a server photo now: hand over to the regular viewer (favorite, albums,
      // menu) in place of this screen, instead of lingering on a "backed up" note
      if (serverId.isNotEmpty) {
        try {
          final remote = await widget.api.asset(serverId);
          if (!mounted) return;
          Navigator.pushReplacement(
            context,
            viewerRoute(AssetViewer(api: widget.api, assets: [remote], initialIndex: 0)),
          );
          return;
        } catch (_) {
          // thumbnail may still be processing or the fetch failed: the note below stands
        }
      }
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Backed up - it is on the server now')));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Backup failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.entity.type == AssetType.video;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_synced ? Icons.cloud_done : Icons.smartphone, size: 18),
            const SizedBox(width: 8),
            Text(_synced ? 'Backed up' : 'Only on this phone'),
          ],
        ),
        actions: [
          if (!_synced)
            IconButton(
              icon: const Icon(Icons.cloud_upload_outlined),
              tooltip: 'Back up this photo',
              onPressed: _busy ? null : _backUp,
            ),
        ],
      ),
      body: Column(
        children: [
          if (_busy) LinearProgressIndicator(value: _pct, minHeight: 2),
          Expanded(
            child: Center(
              child: FutureBuilder<Uint8List?>(
                future: widget.entity.thumbnailDataWithSize(const ThumbnailSize(2000, 2000)),
                builder: (context, s) => s.data == null
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : InteractiveViewer(maxScale: 5, child: Image.memory(s.data!, fit: BoxFit.contain)),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  _synced
                      ? 'On the server. Favorites, albums and viewing from other devices work on the '
                        'server copy - find it under Server, or in All.'
                      : 'Not on the server yet. Back it up to favorite it, add it to albums, '
                        '${isVideo ? 'play it' : 'see it'} from anywhere, and free the space here.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (!_synced) ...[
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _busy ? null : _backUp,
                    icon: const Icon(Icons.cloud_upload_outlined, size: 18),
                    label: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Text(_busy
                          ? (_pct == null ? 'Preparing…' : 'Backing up ${(_pct! * 100).round()}%')
                          : 'Back up this ${isVideo ? 'video' : 'photo'}'),
                    ),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, textAlign: TextAlign.center,
                      style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 13)),
                ],
              ],
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
  bool _chrome = true; // tap the photo: bars away, black background (tap again to bring them back)
  bool _downloading = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _precacheAround(_index);
  }

  /// Warm the neighbours' previews so a swipe lands on a ready image.
  void _precacheAround(int i) {
    for (final j in [i - 1, i + 1]) {
      if (j < 0 || j >= widget.assets.length) continue;
      final a = widget.assets[j];
      if (a.assetType == 'image') {
        precacheImage(NetworkImage(widget.api.previewUrl(a.id), headers: widget.api.authHeaders), context)
            .catchError((_) {});
      }
    }
  }
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
    // Same chrome as every other screen (paper bar, ink text, hairline). Tapping the
    // photo hides it and goes black for an immersive look; tapping again restores it.
    return Scaffold(
      backgroundColor: _chrome ? Theme.of(context).scaffoldBackgroundColor : Colors.black,
      appBar: !_chrome
          ? null
          : AppBar(
        title: Text('${_index + 1} / ${widget.assets.length}'),
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
        allowImplicitScrolling: true, // neighbours are built (and start loading) early
        itemCount: widget.assets.length,
        onPageChanged: (i) {
          setState(() {
            _index = i;
            _stopVideo();
          });
          _precacheAround(i);
        },
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
                      GestureDetector(
                        onTap: () => setState(() => _chrome = !_chrome),
                        child: InteractiveViewer(
                          maxScale: 5,
                          // the grid's thumbnail is already in memory: show it at once under
                          // the preview, which fades in over it when it arrives (no spinner,
                          // no pop)
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              if (a.thumbStatus == 'done')
                                Positioned.fill(
                                  child: Image.network(
                                    widget.api.thumbUrl(a.id),
                                    headers: widget.api.authHeaders,
                                    cacheWidth: 360,
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.low,
                                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                                  ),
                                ),
                              Positioned.fill(
                                child: Image.network(
                                  widget.api.previewUrl(a.id),
                                  headers: widget.api.authHeaders,
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
                                  frameBuilder: (context, child, frame, wasSync) => wasSync
                                      ? child
                                      : AnimatedOpacity(
                                          opacity: frame == null ? 0 : 1,
                                          duration: const Duration(milliseconds: 220),
                                          curve: Curves.easeOut,
                                          child: child,
                                        ),
                                  errorBuilder: (_, _, _) => const Center(child: Icon(Icons.broken_image, size: 48)),
                                ),
                              ),
                            ],
                          ),
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
