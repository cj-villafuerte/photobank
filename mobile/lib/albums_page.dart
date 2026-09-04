import 'package:flutter/material.dart';

import 'api.dart';
import 'library_page.dart';

class AlbumsPage extends StatefulWidget {
  final PhotobankApi api;
  const AlbumsPage({super.key, required this.api});
  @override
  State<AlbumsPage> createState() => _AlbumsPageState();
}

class _AlbumsPageState extends State<AlbumsPage> {
  List<Album>? _albums;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _albums = null;
      _error = null;
    });
    try {
      final a = await widget.api.albums();
      if (mounted) setState(() => _albums = a);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _create() async {
    final name = await _promptName(context, 'New album');
    if (name == null || name.isEmpty) return;
    final album = await widget.api.createAlbum(name);
    if (!mounted) return;
    await Navigator.push(
        context, MaterialPageRoute(builder: (_) => AlbumDetailPage(api: widget.api, albumId: album.id)));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final albums = _albums;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Albums'),
        actions: [IconButton(icon: const Icon(Icons.add), tooltip: 'New album', onPressed: _create)],
      ),
      body: _error != null
          ? Center(child: Text('Could not load: $_error'))
          : albums == null
              ? const Center(child: CircularProgressIndicator())
              : albums.isEmpty
                  ? const Center(child: Text('No albums yet - tap + to create one.'))
                  : RefreshIndicator(
                      onRefresh: _load,
                      child: GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2, crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 0.9),
                        itemCount: albums.length,
                        itemBuilder: (context, i) {
                          final al = albums[i];
                          return Card(
                            clipBehavior: Clip.antiAlias,
                            child: InkWell(
                              onTap: () async {
                                await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                        builder: (_) => AlbumDetailPage(api: widget.api, albumId: al.id)));
                                _load();
                              },
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Expanded(
                                    child: al.coverAssetId == null
                                        ? const Center(child: Icon(Icons.photo_album_outlined, size: 40))
                                        : Image.network(widget.api.thumbUrl(al.coverAssetId!),
                                            headers: widget.api.authHeaders, cacheWidth: 360, fit: BoxFit.cover),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(al.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(fontWeight: FontWeight.w600)),
                                        Text('${al.assetCount} item${al.assetCount == 1 ? '' : 's'}',
                                            style: Theme.of(context).textTheme.bodySmall),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
    );
  }
}

class AlbumDetailPage extends StatefulWidget {
  final PhotobankApi api;
  final String albumId;
  const AlbumDetailPage({super.key, required this.api, required this.albumId});
  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  Album? _album;
  List<RemoteAsset>? _assets;
  String? _error;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _selected.clear();
    });
    try {
      final (album, assets) = await widget.api.album(widget.albumId);
      if (mounted) {
        setState(() {
          _album = album;
          _assets = assets;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _rename() async {
    final name = await _promptName(context, 'Rename album', initial: _album?.name);
    if (name == null || name.isEmpty) return;
    await widget.api.renameAlbum(widget.albumId, name);
    _load();
  }

  Future<void> _deleteAlbum() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete album?'),
        content: const Text('Photos stay in your library; only the album is removed.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.api.deleteAlbum(widget.albumId);
    if (mounted) Navigator.pop(context);
  }

  Future<void> _removeSelected() async {
    await widget.api.removeFromAlbum(widget.albumId, _selected.toList());
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final assets = _assets;
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected.isEmpty ? (_album?.name ?? 'Album') : '${_selected.length} selected'),
        actions: [
          if (_selected.isNotEmpty)
            IconButton(icon: const Icon(Icons.remove_circle_outline), tooltip: 'Remove from album', onPressed: _removeSelected)
          else ...[
            IconButton(icon: const Icon(Icons.edit), tooltip: 'Rename', onPressed: _rename),
            IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Delete album', onPressed: _deleteAlbum),
          ],
        ],
      ),
      body: _error != null
          ? Center(child: Text('Could not load: $_error'))
          : assets == null
              ? const Center(child: CircularProgressIndicator())
              : assets.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('Empty album - open a photo in the Library and use "Add to album".',
                            textAlign: TextAlign.center),
                      ),
                    )
                  : GridView.builder(
                      padding: const EdgeInsets.all(4),
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2),
                      itemCount: assets.length,
                      itemBuilder: (context, i) {
                        final a = assets[i];
                        final isSel = _selected.contains(a.id);
                        return GestureDetector(
                          onTap: () {
                            if (_selected.isNotEmpty) {
                              setState(() => isSel ? _selected.remove(a.id) : _selected.add(a.id));
                            } else {
                              Navigator.push(
                                  context, viewerRoute(AssetViewer(api: widget.api, assets: assets, initialIndex: i)));
                            }
                          },
                          onLongPress: () => setState(() => isSel ? _selected.remove(a.id) : _selected.add(a.id)),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              Image.network(widget.api.thumbUrl(a.id), headers: widget.api.authHeaders, cacheWidth: 360, fit: BoxFit.cover),
                              if (isSel)
                                Container(
                                  decoration: BoxDecoration(
                                      border: Border.all(color: Theme.of(context).colorScheme.primary, width: 3),
                                      color: Colors.black38),
                                  child: const Icon(Icons.check_circle, size: 28),
                                ),
                            ],
                          ),
                        );
                      },
                    ),
    );
  }
}

Future<String?> _promptName(BuildContext context, String title, {String? initial}) {
  final ctrl = TextEditingController(text: initial ?? '');
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(controller: ctrl, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('OK')),
      ],
    ),
  );
}

/// Bottom sheet: pick an album (or create one) to add [assetIds] to.
Future<void> showAddToAlbumSheet(BuildContext context, PhotobankApi api, List<String> assetIds) async {
  List<Album> albums;
  try {
    albums = await api.albums();
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not load albums: $e')));
    }
    return;
  }
  if (!context.mounted) return;
  final chosen = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          const ListTile(title: Text('Add to album', style: TextStyle(fontWeight: FontWeight.w600))),
          ListTile(
            leading: const Icon(Icons.add),
            title: const Text('New album…'),
            onTap: () => Navigator.pop(ctx, '__new__'),
          ),
          for (final al in albums)
            ListTile(
              leading: const Icon(Icons.photo_album_outlined),
              title: Text(al.name),
              subtitle: Text('${al.assetCount} items'),
              onTap: () => Navigator.pop(ctx, al.id),
            ),
        ],
      ),
    ),
  );
  if (chosen == null || !context.mounted) return;
  String albumId = chosen;
  if (chosen == '__new__') {
    final name = await _promptName(context, 'New album');
    if (name == null || name.isEmpty) return;
    albumId = (await api.createAlbum(name)).id;
  }
  await api.addToAlbum(albumId, assetIds);
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Added to album')));
  }
}
