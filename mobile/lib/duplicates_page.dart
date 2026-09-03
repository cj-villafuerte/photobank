import 'package:flutter/material.dart';

import 'api.dart';
import 'format.dart';

/// Visually similar images grouped by perceptual fingerprint; trash the extras.
class DuplicatesPage extends StatefulWidget {
  final PhotobankApi api;
  const DuplicatesPage({super.key, required this.api});
  @override
  State<DuplicatesPage> createState() => _DuplicatesPageState();
}

class _DuplicatesPageState extends State<DuplicatesPage> {
  List<DuplicateGroup>? _groups;
  String? _error;
  // per group: ids selected for removal (default: all but the largest)
  final Map<int, Set<String>> _selected = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _groups = null;
      _error = null;
      _selected.clear();
    });
    try {
      final g = await widget.api.duplicates();
      for (var i = 0; i < g.length; i++) {
        _selected[i] = g[i].assets.skip(1).map((a) => a.id).toSet();
      }
      if (mounted) setState(() => _groups = g);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _trash(int gi) async {
    final ids = _selected[gi] ?? {};
    final group = _groups![gi];
    if (ids.length >= group.assets.length) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Keep at least one copy')));
      return;
    }
    for (final id in ids) {
      await widget.api.trashAsset(id);
    }
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${ids.length} moved to trash')));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final groups = _groups;
    final total = groups?.fold<int>(0, (s, g) => s + g.wastedBytes) ?? 0;
    return Scaffold(
      appBar: AppBar(title: const Text('Duplicates')),
      body: _error != null
          ? Center(child: Text('Could not load: $_error'))
          : groups == null
              ? const Center(child: CircularProgressIndicator())
              : groups.isEmpty
                  ? const Center(child: Text('No duplicate-looking images found. 🎉'))
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: groups.length + 1,
                      itemBuilder: (context, i) {
                        if (i == 0) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Text(
                              '${groups.length} groups · ${fmtBytes(total)} reclaimable. '
                              'Copies (all but the largest) are preselected; trashed items can be '
                              'restored until you empty the trash.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          );
                        }
                        final gi = i - 1;
                        final g = groups[gi];
                        final sel = _selected[gi]!;
                        final savable = g.assets
                            .where((a) => sel.contains(a.id))
                            .fold<int>(0, (s, a) => s + a.fileSize);
                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          child: Padding(
                            padding: const EdgeInsets.all(10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text('${g.assets.length} similar · '
                                          '${fmtBytes(g.wastedBytes)} reclaimable',
                                          style: Theme.of(context).textTheme.bodySmall),
                                    ),
                                    FilledButton.tonal(
                                      onPressed: sel.isEmpty ? null : () => _trash(gi),
                                      child: Text('Trash ${sel.length} '
                                          '(${fmtBytes(savable)})'),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                SizedBox(
                                  height: 150,
                                  child: ListView.separated(
                                    scrollDirection: Axis.horizontal,
                                    itemCount: g.assets.length,
                                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                                    itemBuilder: (context, ai) {
                                      final a = g.assets[ai];
                                      final isSel = sel.contains(a.id);
                                      return GestureDetector(
                                        onTap: () => setState(
                                            () => isSel ? sel.remove(a.id) : sel.add(a.id)),
                                        child: SizedBox(
                                          width: 110,
                                          child: Column(
                                            children: [
                                              Expanded(
                                                child: Stack(
                                                  fit: StackFit.expand,
                                                  children: [
                                                    ClipRRect(
                                                      borderRadius: BorderRadius.circular(4),
                                                      child: Image.network(widget.api.thumbUrl(a.id),
                                                          headers: widget.api.authHeaders, cacheWidth: 360,
                                                          fit: BoxFit.cover),
                                                    ),
                                                    if (isSel)
                                                      Container(
                                                        decoration: BoxDecoration(
                                                          borderRadius: BorderRadius.circular(4),
                                                          border: Border.all(
                                                              color: Theme.of(context).colorScheme.primary,
                                                              width: 3),
                                                          color: Colors.black38,
                                                        ),
                                                        child: const Icon(Icons.delete, size: 26),
                                                      ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                '${fmtBytes(a.fileSize)}'
                                                '${a.width != null ? ' · ${a.width}×${a.height}' : ''}',
                                                style: const TextStyle(fontSize: 10),
                                              ),
                                              Text(ai == 0 && !isSel ? 'keeping' : ' ',
                                                  style: TextStyle(
                                                      fontSize: 10,
                                                      color: Theme.of(context).colorScheme.onSurfaceVariant)),
                                            ],
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}
