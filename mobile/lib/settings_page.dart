import 'package:flutter/material.dart';

import 'api.dart';
import 'library_page.dart';

class SettingsPage extends StatefulWidget {
  final PhotobankApi api;
  final Future<void> Function() onLogout;
  const SettingsPage({super.key, required this.api, required this.onLogout});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, dynamic>? _me;

  @override
  void initState() {
    super.initState();
    widget.api.me().then((m) {
      if (mounted) setState(() => _me = m);
    }).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final me = _me;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Profile', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Card(
            child: me == null
                ? const Padding(
                    padding: EdgeInsets.all(20),
                    child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.person),
                        title: Text(me['display_name']?.toString() ?? ''),
                        subtitle: Text(me['email']?.toString() ?? ''),
                        trailing: (me['is_admin'] == true)
                            ? const Chip(label: Text('Admin'))
                            : null,
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: 20),
          Text('Server', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.dns),
              title: Text(widget.api.baseUrl),
              subtitle: const Text('Change passwords and manage users in the web app'),
            ),
          ),
          const SizedBox(height: 20),
          Card(
            child: ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('Log out'),
              onTap: () => widget.onLogout(),
            ),
          ),
          const SizedBox(height: 120),
          const Divider(),
          const SizedBox(height: 8),
          Card(
            child: ListTile(
              leading: const Icon(Icons.visibility_off),
              title: const Text('Hidden photos'),
              subtitle: const Text('Only visible here'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => HiddenPage(api: widget.api)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class HiddenPage extends StatefulWidget {
  final PhotobankApi api;
  const HiddenPage({super.key, required this.api});
  @override
  State<HiddenPage> createState() => _HiddenPageState();
}

class _HiddenPageState extends State<HiddenPage> {
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
      final assets = await widget.api.hiddenAssets();
      if (mounted) setState(() => _assets = assets);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _unhideSelected() async {
    await widget.api.unhideAssets(_selected.toList());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${_selected.length} restored to the timeline')));
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final assets = _assets;
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected.isEmpty ? 'Hidden photos' : '${_selected.length} selected'),
        actions: [
          if (_selected.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.visibility),
              tooltip: 'Unhide',
              onPressed: _unhideSelected,
            ),
        ],
      ),
      body: _error != null
          ? Center(child: Text('Could not load: $_error'))
          : assets == null
              ? const Center(child: CircularProgressIndicator())
              : assets.isEmpty
                  ? const Center(child: Text('Nothing is hidden.'))
                  : Column(
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(8),
                          child: Text('Tap to view · long-press to select',
                              style: TextStyle(fontSize: 12)),
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
                                onTap: () {
                                  if (_selected.isNotEmpty) {
                                    setState(() =>
                                        isSel ? _selected.remove(a.id) : _selected.add(a.id));
                                  } else {
                                    Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => AssetViewer(
                                            api: widget.api, assets: assets, initialIndex: i),
                                      ),
                                    );
                                  }
                                },
                                onLongPress: () => setState(() =>
                                    isSel ? _selected.remove(a.id) : _selected.add(a.id)),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    Image.network(
                                      widget.api.thumbUrl(a.id),
                                      headers: widget.api.authHeaders,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => Container(
                                          color: Colors.white10,
                                          child: const Icon(Icons.broken_image, size: 18)),
                                    ),
                                    if (isSel)
                                      Container(
                                        decoration: BoxDecoration(
                                          border: Border.all(
                                              color: Theme.of(context).colorScheme.primary,
                                              width: 3),
                                          color: Colors.black38,
                                        ),
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
