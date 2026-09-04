import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'format.dart';
import 'sync_service.dart';
import 'background.dart' show backlogThreshold;
import 'duplicates_page.dart';
import 'library_page.dart';
import 'notifications.dart';
import 'onboarding_page.dart';
import 'trash_page.dart';

class SettingsPage extends StatefulWidget {
  final PhotobankApi api;
  final Future<void> Function() onLogout;
  const SettingsPage({super.key, required this.api, required this.onLogout});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  Map<String, dynamic>? _me;
  bool _retention = false;
  int _months = 2;
  bool _notify = false;

  @override
  void initState() {
    super.initState();
    widget.api.me().then((m) {
      if (mounted) setState(() => _me = m);
    }).catchError((_) {});
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _retention = p.getBool('retention_enabled') ?? false;
        _months = p.getInt('retention_months') ?? 2;
        _notify = p.getBool('notify_backlog') ?? false;
      });
    });
    _measureAppData();
  }

  Future<void> _setRetention(bool on) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('retention_enabled', on);
    setState(() => _retention = on);
  }

  Future<void> _setMonths(int m) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('retention_months', m);
    setState(() => _months = m);
  }

  int? _cacheBytes;
  int? _syncRecords;

  Future<List<Directory>> _cacheDirs() async {
    final dirs = <Directory>[await getTemporaryDirectory()];
    try {
      dirs.add(await getApplicationCacheDirectory()); // photo_manager's copies live here
    } catch (_) {}
    return dirs;
  }

  Future<void> _measureAppData() async {
    try {
      var total = 0;
      for (final dir in await _cacheDirs()) {
        if (!dir.existsSync()) continue;
        await for (final f in dir.list(recursive: true, followLinks: false)) {
          if (f is File) {
            try {
              total += await f.length();
            } catch (_) {}
          }
        }
      }
      final svc = SyncService(widget.api);
      await svc.init();
      if (mounted) {
        setState(() {
          _cacheBytes = total;
          _syncRecords = svc.syncedCount;
        });
      }
    } catch (_) {}
  }

  Future<void> _clearCache() async {
    try {
      try {
        await PhotoManager.clearFileCache();
      } catch (_) {}
      for (final dir in await _cacheDirs()) {
        if (!dir.existsSync()) continue;
        await for (final f in dir.list(followLinks: false)) {
          try {
            await f.delete(recursive: true);
          } catch (_) {}
        }
      }
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      _toast('Cache cleared');
    } catch (e) {
      _toast('Could not clear cache: $e');
    }
    _measureAppData();
  }

  Future<void> _resetSyncRecords() async {
    final ok = await _confirm(
      'Reset sync records?',
      'The app forgets which photos are backed up. Nothing is deleted anywhere; the next '
      'sync re-checks every item against the server (it re-hashes, so it takes a while, '
      'but nothing re-uploads).',
      'Reset',
    );
    if (!ok) return;
    final svc = SyncService(widget.api);
    await svc.init();
    await svc.clearLocalState();
    _toast('Sync records reset');
    _measureAppData();
  }

  Future<void> _eraseEverything() async {
    final ok = await _confirm(
      'Erase app data and log out?',
      'Removes the login, server address, settings, sync records and cache from this phone. '
      'Your photos on the server and on this phone are untouched.',
      'Erase',
    );
    if (!ok) return;
    await _clearCache();
    final p = await SharedPreferences.getInstance();
    await p.clear();
    await widget.onLogout();
  }

  Future<bool> _confirm(String title, String body, String action) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(title),
            content: Text(body),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
            ],
          ),
        ) ??
        false;
  }

  void _toast(String m) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));
  }

  // The hidden-photos entry is not in the list until the reader reaches the end
  // and keeps dragging past it (finger down - a fling's overshoot doesn't count).
  bool _hiddenRevealed = false;
  double _pull = 0;
  static const _revealPull = 72.0;

  bool _onScroll(ScrollNotification n) {
    if (_hiddenRevealed) return false;
    double over;
    if (n is OverscrollNotification) {
      // clamping physics (Android): per-event deltas past the edge
      if (n.dragDetails == null) return false;
      _pull += n.overscroll > 0 ? n.overscroll : 0;
      over = _pull;
    } else if (n is ScrollUpdateNotification) {
      // bouncing physics (iOS): position runs past maxScrollExtent while dragging
      if (n.dragDetails == null) return false;
      over = n.metrics.pixels - n.metrics.maxScrollExtent;
      if (over <= 0) _pull = 0;
    } else if (n is ScrollEndNotification) {
      _pull = 0;
      return false;
    } else {
      return false;
    }
    if (over >= _revealPull) {
      HapticFeedback.mediumImpact();
      setState(() => _hiddenRevealed = true);
    }
    return false;
  }

  Future<void> _setNotify(bool on) async {
    if (on && !await requestNotificationPermission()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Notifications are blocked - enable them in iOS Settings > Photobank')));
      }
      return;
    }
    final p = await SharedPreferences.getInstance();
    await p.setBool('notify_backlog', on);
    setState(() => _notify = on);
  }

  @override
  Widget build(BuildContext context) {
    final me = _me;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
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
          // the public demo server never removes anything from the phone
          if (widget.api.demo == null) ...[
          const SizedBox(height: 20),
          Text('Phone storage', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  title: const Text('Keep on this phone'),
                  subtitle: Text(_months == 0
                      ? 'Nothing - "Free up space" removes every backed-up item.'
                      : 'The last $_months month${_months == 1 ? '' : 's'}. "Free up space" removes '
                        'backed-up items older than that.'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final m in [1, 2, 3, 6, 12, 24])
                            ChoiceChip(
                              label: Text('$m mo'),
                              selected: _months == m,
                              onSelected: (_) => _setMonths(m),
                            ),
                          ChoiceChip(
                            label: const Text('Nothing'),
                            selected: _months == 0,
                            onSelected: (_) => _setMonths(0),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Text('Custom:'),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 72,
                            child: TextFormField(
                              key: ValueKey(_months),
                              initialValue: _months == 0 ? '' : '$_months',
                              keyboardType: TextInputType.number,
                              textAlign: TextAlign.center,
                              decoration: const InputDecoration(isDense: true, hintText: 'months'),
                              onFieldSubmitted: (v) {
                                final m = int.tryParse(v.trim());
                                if (m != null && m >= 0 && m <= 240) _setMonths(m);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Text('months'),
                        ],
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Remove older items automatically'),
                  subtitle: Text(_retention
                      ? 'Applies the window above during background backups (server-verified first).'
                      : 'Off - only the "Free up space" button removes anything.'),
                  value: _retention,
                  onChanged: _setRetention,
                ),
                const Divider(height: 1),
                SwitchListTile(
                  title: const Text('Remind me when backups pile up'),
                  subtitle: const Text(
                      'Notification once $backlogThreshold+ items are waiting (needs Background backup on).'),
                  value: _notify,
                  onChanged: _setNotify,
                ),
              ],
            ),
          ),
          ],
          const SizedBox(height: 20),
          Text('Server storage', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.cleaning_services),
                  title: const Text('Find duplicate photos'),
                  subtitle: const Text('Visually similar copies on the server'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => DuplicatesPage(api: widget.api)),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Trash'),
                  subtitle: const Text('Restore or permanently delete'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => TrashPage(api: widget.api)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text('App data on this phone', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.cached),
                  title: const Text('Clear cache'),
                  subtitle: Text(_cacheBytes == null
                      ? 'Temporary files and thumbnails'
                      : 'Temporary files and thumbnails · ${fmtBytes(_cacheBytes!)}'),
                  onTap: _clearCache,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.history),
                  title: const Text('Reset sync records'),
                  subtitle: Text(_syncRecords == null
                      ? 'Re-verify everything against the server'
                      : '$_syncRecords items tracked · re-verify against the server'),
                  onTap: _resetSyncRecords,
                ),
                const Divider(height: 1),
                ListTile(
                  leading: Icon(Icons.delete_sweep, color: Theme.of(context).colorScheme.error),
                  title: const Text('Erase app data & log out'),
                  subtitle: const Text('Login, settings, records, cache - photos untouched'),
                  onTap: _eraseEverything,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.school_outlined),
                  title: const Text('Show the tour again'),
                  subtitle: const Text('The five-step introduction'),
                  onTap: () => Navigator.push(
                      context, MaterialPageRoute(builder: (_) => const OnboardingPage(), fullscreenDialog: true)),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('Log out'),
                  onTap: () => widget.onLogout(),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // the technical bits, out of the way of people who don't need them
          Card(
            child: ExpansionTile(
              leading: const Icon(Icons.tune),
              title: const Text('Advanced'),
              subtitle: const Text('Server address and account details'),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              children: [
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Server address'),
                  subtitle: SelectableText(widget.api.baseUrl),
                ),
                if (me != null)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Signed in as'),
                    subtitle: Text(me['email']?.toString() ?? ''),
                  ),
                Text(
                  'Passwords and member accounts are managed in the Photobank app on the computer '
                  '(or its web page at the address above).',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          if (_hiddenRevealed) ...[
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
        ],
        ),
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
                                      viewerRoute(AssetViewer(api: widget.api, assets: assets, initialIndex: i)),
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
                                      headers: widget.api.authHeaders, cacheWidth: 360,
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
