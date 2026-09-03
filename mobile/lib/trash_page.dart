import 'package:flutter/material.dart';

import 'api.dart';

class TrashPage extends StatefulWidget {
  final PhotobankApi api;
  const TrashPage({super.key, required this.api});
  @override
  State<TrashPage> createState() => _TrashPageState();
}

class _TrashPageState extends State<TrashPage> {
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
      _assets = null;
      _error = null;
      _selected.clear();
    });
    try {
      final a = await widget.api.trash();
      if (mounted) setState(() => _assets = a);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _restore() async {
    await widget.api.restoreFromTrash(_selected.toList());
    _toast('${_selected.length} restored');
    _load();
  }

  Future<void> _deleteForever() async {
    final ok = await _confirm(
        'Permanently delete ${_selected.length} item(s)?', 'This cannot be undone.');
    if (!ok) return;
    for (final id in _selected) {
      await widget.api.permanentDelete(id);
    }
    _toast('Deleted permanently');
    _load();
  }

  Future<void> _empty() async {
    if (!await _confirm('Empty trash?', 'Everything in the trash is deleted permanently.')) return;
    await widget.api.emptyTrash();
    _toast('Trash emptied');
    _load();
  }

  Future<bool> _confirm(String title, String body) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
            ],
          ),
        ) ??
        false;
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  @override
  Widget build(BuildContext context) {
    final assets = _assets;
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected.isEmpty ? 'Trash' : '${_selected.length} selected'),
        actions: [
          if (_selected.isNotEmpty) ...[
            IconButton(icon: const Icon(Icons.restore), tooltip: 'Restore', onPressed: _restore),
            IconButton(icon: const Icon(Icons.delete_forever), tooltip: 'Delete forever', onPressed: _deleteForever),
          ] else if (assets != null && assets.isNotEmpty)
            TextButton(onPressed: _empty, child: const Text('Empty')),
        ],
      ),
      body: _error != null
          ? Center(child: Text('Could not load: $_error'))
          : assets == null
              ? const Center(child: CircularProgressIndicator())
              : assets.isEmpty
                  ? const Center(child: Text('Trash is empty.'))
                  : Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(8),
                          child: Text('Long-press to select · restore or delete forever', style: TextStyle(fontSize: 12)),
                        ),
                        Expanded(
                          child: GridView.builder(
                            padding: const EdgeInsets.all(4),
                            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3, crossAxisSpacing: 2, mainAxisSpacing: 2),
                            itemCount: assets.length,
                            itemBuilder: (context, i) {
                              final a = assets[i];
                              final isSel = _selected.contains(a.id);
                              return GestureDetector(
                                onTap: () => setState(() => isSel ? _selected.remove(a.id) : _selected.add(a.id)),
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
                        ),
                      ],
                    ),
    );
  }
}
