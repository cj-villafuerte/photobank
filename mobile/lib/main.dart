import 'package:background_fetch/background_fetch.dart';
import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'api.dart';
import 'background.dart';
import 'library_page.dart';
import 'settings_page.dart';
import 'sync_service.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PhotobankApp());
  initBackgroundBackup();
  BackgroundFetch.registerHeadlessTask(backgroundFetchHeadlessTask);
}

class PhotobankApp extends StatelessWidget {
  const PhotobankApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Photobank',
      theme: photobankTheme(),
      home: const RootGate(),
    );
  }
}

/// Decides between the setup screen and the sync screen based on stored config.
class RootGate extends StatefulWidget {
  const RootGate({super.key});
  @override
  State<RootGate> createState() => _RootGateState();
}

class _RootGateState extends State<RootGate> {
  bool _loading = true;
  PhotobankApi? _api;

  @override
  void initState() {
    super.initState();
    _restore();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('server_url');
    final token = prefs.getString('token');
    if (url != null && token != null) {
      _api = PhotobankApi(baseUrl: url, token: token);
    }
    setState(() => _loading = false);
  }

  void _onLoggedIn(PhotobankApi api) => setState(() => _api = api);

  Future<void> _onLogout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('token');
    setState(() => _api = null);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (_api == null) return SetupPage(onLoggedIn: _onLoggedIn);
    return HomeShell(api: _api!, onLogout: _onLogout);
  }
}

/// Bottom navigation between the backup screen and the server library.
class HomeShell extends StatefulWidget {
  final PhotobankApi api;
  final Future<void> Function() onLogout;
  const HomeShell({super.key, required this.api, required this.onLogout});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          SyncPage(api: widget.api, onLogout: widget.onLogout),
          Scaffold(
            appBar: AppBar(title: const Text('Library')),
            body: LibraryPage(api: widget.api),
          ),
          SettingsPage(api: widget.api, onLogout: widget.onLogout),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.cloud_upload_outlined), selectedIcon: Icon(Icons.cloud_upload), label: 'Backup'),
          NavigationDestination(icon: Icon(Icons.photo_library_outlined), selectedIcon: Icon(Icons.photo_library), label: 'Library'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

class FoundServer {
  final String name;
  final String url;
  const FoundServer(this.name, this.url);
}

class SetupPage extends StatefulWidget {
  final void Function(PhotobankApi) onLoggedIn;
  const SetupPage({super.key, required this.onLoggedIn});
  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final Map<String, FoundServer> _found = {};
  BonsoirDiscovery? _discovery;
  bool _manual = false;
  final _url = TextEditingController(text: 'http://192.168.');

  @override
  void initState() {
    super.initState();
    _startDiscovery();
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString('server_url');
      if (saved != null) _url.text = saved;
    });
  }

  Future<void> _startDiscovery() async {
    try {
      final discovery = BonsoirDiscovery(type: '_photobank._tcp');
      _discovery = discovery;
      await discovery.ready;
      discovery.eventStream!.listen((event) {
        final service = event.service;
        if (service == null || !mounted) return;
        if (event.type == BonsoirDiscoveryEventType.discoveryServiceFound) {
          service.resolve(discovery.serviceResolver);
        } else if (event.type == BonsoirDiscoveryEventType.discoveryServiceResolved) {
          final json = service.toJson();
          final port = json['service.port'] ?? json['port'] ?? 8000;
          // prefer the numeric IP from TXT metadata: Dart's HTTP client
          // cannot resolve .local mDNS hostnames on iOS/Android
          String? host = service.attributes['ip'];
          if (host == null || host.isEmpty) {
            host = (json['service.host'] ?? json['host'])?.toString();
            if (host != null && host.endsWith('.')) {
              host = host.substring(0, host.length - 1);
            }
          }
          if (host != null && host.isNotEmpty) {
            final displayName =
                (service.attributes['name']?.isNotEmpty ?? false) ? service.attributes['name']! : service.name;
            setState(() {
              _found[service.name] = FoundServer(displayName, 'http://$host:$port');
            });
          }
        } else if (event.type == BonsoirDiscoveryEventType.discoveryServiceLost) {
          setState(() => _found.remove(service.name));
        }
      });
      await discovery.start();
    } catch (_) {
      // discovery unavailable (permissions, platform) - manual entry still works
      if (mounted) setState(() => _manual = true);
    }
  }

  @override
  void dispose() {
    _discovery?.stop();
    _url.dispose();
    super.dispose();
  }

  String _normalizedManualUrl() {
    var url = _url.text.trim();
    if (url.endsWith('/')) url = url.substring(0, url.length - 1);
    if (!url.startsWith('http')) url = 'http://$url';
    return url;
  }

  Future<void> _loginTo(String url, String serverLabel) async {
    // pause mDNS traffic while talking to the server
    final api = PhotobankApi(baseUrl: url);
    try {
      await api.checkHealth();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Cannot reach $serverLabel - is the phone on the same Wi-Fi?'),
      ));
      return;
    }
    if (!mounted) return;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _LoginSheet(api: api, serverLabel: serverLabel),
    );
    if (ok == true) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('server_url', url);
      await prefs.setString('token', api.token!);
      widget.onLoggedIn(api);
    }
  }

  @override
  Widget build(BuildContext context) {
    final servers = _found.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('📷', textAlign: TextAlign.center, style: TextStyle(fontSize: 56)),
                const SizedBox(height: 8),
                Text('Photobank', textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 28),
                Row(
                  children: [
                    const SizedBox(
                      width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 10),
                    Text('Looking for servers on your network…',
                        style: Theme.of(context).textTheme.bodyMedium),
                  ],
                ),
                const SizedBox(height: 12),
                if (servers.isEmpty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'No servers found yet. Make sure the Photobank server is '
                        'running and this phone is on the same Wi-Fi.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                for (final s in servers)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.dns),
                      title: Text(s.name),
                      subtitle: Text(s.url),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _loginTo(s.url, s.name),
                    ),
                  ),
                const SizedBox(height: 20),
                if (!_manual)
                  TextButton(
                    onPressed: () => setState(() => _manual = true),
                    child: const Text('Enter address manually'),
                  )
                else ...[
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Server URL',
                      hintText: 'http://192.168.1.23:8000',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => _loginTo(_normalizedManualUrl(), _normalizedManualUrl()),
                    child: const Padding(padding: EdgeInsets.all(12), child: Text('Connect')),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Email/password prompt shown after tapping a discovered server.
class _LoginSheet extends StatefulWidget {
  final PhotobankApi api;
  final String serverLabel;
  const _LoginSheet({required this.api, required this.serverLabel});
  @override
  State<_LoginSheet> createState() => _LoginSheetState();
}

class _LoginSheetState extends State<_LoginSheet> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString('email');
      if (saved != null && mounted) setState(() => _email.text = saved);
    });
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.login(_email.text.trim(), _password.text);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('email', _email.text.trim());
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Login failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 24, right: 24, top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Log in to ${widget.serverLabel}',
              style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
            onSubmitted: (_) => _login(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _busy ? null : _login,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(_busy ? 'Logging in…' : 'Log in'),
            ),
          ),
        ],
      ),
    );
  }
}

class SyncPage extends StatefulWidget {
  final PhotobankApi api;
  final Future<void> Function() onLogout;
  const SyncPage({super.key, required this.api, required this.onLogout});
  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  late final SyncService _service = SyncService(widget.api);
  DeviceStats? _stats;
  SyncProgress? _progress;
  int _fileSent = 0;
  int _fileTotal = 0;
  String _fileStatus = 'preparing…';
  bool _syncing = false;
  bool _oldestFirst = false;
  bool _bgBackup = false;
  String? _lastBgSync;
  bool _permissionDenied = false;
  String? _lastResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _service.init();
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _oldestFirst = prefs.getBool('sync_oldest_first') ?? false;
        _bgBackup = prefs.getBool('bg_backup') ?? false;
        _lastBgSync = prefs.getString('last_bg_sync');
      });
    }
    final ok = await _service.requestPermission();
    if (!ok) {
      setState(() => _permissionDenied = true);
      return;
    }
    final stats = await _service.stats();
    if (mounted) setState(() => _stats = stats);
  }

  Future<void> _sync() async {
    setState(() {
      _syncing = true;
      _lastResult = null;
    });
    // keep the screen awake so iOS doesn't suspend the app mid-backup
    try {
      await WakelockPlus.enable();
    } catch (_) {}
    try {
      SyncProgress? last;
      await for (final p in _service.sync(
          oldestFirst: _oldestFirst,
          onStatus: (status) {
        if (mounted) setState(() => _fileStatus = status);
      }, onFileProgress: (sent, total) {
        if (mounted) {
          setState(() {
            _fileSent = sent;
            _fileTotal = total;
          });
        }
      })) {
        last = p;
        if (mounted) {
          setState(() {
            _progress = p;
            _fileSent = 0;
            _fileTotal = 0;
            _fileStatus = 'preparing…';
          });
        }
      }
      if (last != null) {
        _lastResult = _service.cancelRequested
            ? 'Sync stopped - ${last.uploaded} uploaded before stopping.'
            : 'Done: ${last.uploaded} uploaded, ${last.skipped} already backed up'
              '${last.failed > 0 ? ', ${last.failed} failed' : ''}.';
      } else {
        _lastResult = 'Everything is already backed up.';
      }
    } on ApiException catch (e) {
      if (e.status == 401) {
        await widget.onLogout();
        return;
      }
      _lastResult = 'Sync failed: ${e.message}';
    } catch (e) {
      _lastResult = 'Sync failed: $e';
    } finally {
      try {
        await WakelockPlus.disable();
      } catch (_) {}
      if (mounted) {
        final stats = await _service.stats();
        setState(() {
          _syncing = false;
          _progress = null;
          _stats = stats;
        });
      }
    }
  }

  Future<void> _verifyLivePhotos() async {
    setState(() {
      _syncing = true;
      _lastResult = null;
    });
    try {
      await WakelockPlus.enable();
    } catch (_) {}
    try {
      SyncProgress? last;
      await for (final p in _service.syncLiveVideos(verifyAll: true)) {
        last = p;
        if (mounted) setState(() => _progress = p);
      }
      _lastResult = last == null
          ? 'All Live Photos already have their videos on the server.'
          : 'Live Photos verified: ${last.uploaded} video'
            '${last.uploaded == 1 ? '' : 's'} uploaded'
            '${last.failed > 0 ? ', ${last.failed} failed (will retry)' : ''}.';
    } on ApiException catch (e) {
      if (e.status == 401) {
        await widget.onLogout();
        return;
      }
      _lastResult = 'Verification failed: ${e.message}';
    } catch (e) {
      _lastResult = 'Verification failed: $e';
    } finally {
      try {
        await WakelockPlus.disable();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _syncing = false;
          _progress = null;
        });
      }
    }
  }

  Future<void> _freeUpSpace() async {
    final stats = _stats;
    if (stats == null || stats.backedUp == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Free up space?'),
        content: Text(
          'This deletes up to ${stats.backedUp} photos/videos from this phone. '
          'Each one is verified to exist on your server first. '
          'iOS will ask you to confirm the deletion.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete from phone')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final n = await _service.freeUpSpace();
      _lastResult = n > 0 ? 'Removed $n items from this phone.' : 'Nothing was deleted.';
    } on ApiException catch (e) {
      _lastResult = 'Could not verify with server: ${e.message}';
    } catch (e) {
      _lastResult = 'Delete failed: $e';
    }
    final s = await _service.stats();
    if (mounted) setState(() => _stats = s);
  }

  @override
  Widget build(BuildContext context) {
    final stats = _stats;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Photobank'),
        actions: [
          IconButton(
            icon: const Icon(Icons.open_in_browser),
            tooltip: 'Open web app',
            onPressed: () => launchUrl(Uri.parse(widget.api.baseUrl), mode: LaunchMode.externalApplication),
          ),
          IconButton(icon: const Icon(Icons.logout), tooltip: 'Log out', onPressed: () => widget.onLogout()),
        ],
      ),
      body: _permissionDenied
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'Photo library access was denied.\nEnable it in Settings > Photobank > Photos ("All Photos").',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : stats == null
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(20),
                    children: [
                      Row(
                        children: [
                          _statCard('On this phone', '${stats.totalOnDevice}'),
                          const SizedBox(width: 12),
                          _statCard('Backed up', '${stats.backedUp}'),
                          const SizedBox(width: 12),
                          _statCard('To sync', '${stats.pending}'),
                        ],
                      ),
                      const SizedBox(height: 24),
                      if (_syncing && _progress != null) ...[
                        LinearProgressIndicator(
                          value: _progress!.total == 0
                              ? null
                              : (_progress!.done +
                                      (_fileTotal > 0 ? _fileSent / _fileTotal : 0)) /
                                  _progress!.total,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'File ${_progress!.done + 1} of ${_progress!.total}',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _fileTotal > 0
                              ? '${_progress!.currentName} - '
                                '${(_fileSent / _fileTotal * 100).clamp(0, 100).toStringAsFixed(0)}% '
                                'of ${_fmtBytes(_fileTotal)}'
                              : '${_progress!.currentName} - $_fileStatus',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: _fileTotal > 0 ? (_fileSent / _fileTotal).clamp(0.0, 1.0) : null,
                          minHeight: 2,
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          onPressed: () => _service.cancelRequested = true,
                          child: const Text('Stop'),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Screen stays awake while backing up.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ] else ...[
                        Row(
                          children: [
                            Text('Sync order', style: Theme.of(context).textTheme.bodyMedium),
                            const Spacer(),
                            SegmentedButton<bool>(
                              segments: const [
                                ButtonSegment(value: false, label: Text('Newest first')),
                                ButtonSegment(value: true, label: Text('Oldest first')),
                              ],
                              selected: {_oldestFirst},
                              onSelectionChanged: (sel) async {
                                setState(() => _oldestFirst = sel.first);
                                final prefs = await SharedPreferences.getInstance();
                                await prefs.setBool('sync_oldest_first', sel.first);
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: stats.pending == 0 ? null : _sync,
                          icon: const Icon(Icons.cloud_upload),
                          label: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(stats.pending == 0
                                ? 'Everything is backed up'
                                : 'Back up ${stats.pending} items'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: stats.backedUp == 0 ? null : _freeUpSpace,
                          icon: const Icon(Icons.cleaning_services),
                          label: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text('Free up space (${stats.backedUp} backed up)'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: stats.backedUp == 0 ? null : _verifyLivePhotos,
                          icon: const Icon(Icons.motion_photos_on),
                          label: const Padding(
                            padding: EdgeInsets.all(12),
                            child: Text('Verify Live Photos'),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Background backup'),
                        subtitle: Text(
                          _bgLine(),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        value: _bgBackup,
                        onChanged: (v) async {
                          setState(() => _bgBackup = v);
                          await setBackgroundBackupEnabled(v);
                        },
                      ),
                      if (_lastResult != null) ...[
                        const SizedBox(height: 20),
                        Card(
                          child: Padding(padding: const EdgeInsets.all(14), child: Text(_lastResult!)),
                        ),
                      ],
                      const SizedBox(height: 20),
                      Text(
                        'Server: ${widget.api.baseUrl}\n'
                        'Backups only run while this app is open. Photos are verified '
                        'on the server before anything is removed from the phone.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
    );
  }

  String _bgLine() {
    const base = 'iOS grants short windows (works best charging on Wi-Fi; '
        'keep Background App Refresh on).';
    final last = _lastBgSync;
    if (last == null) return base;
    final parts = last.split('|');
    final when = DateTime.tryParse(parts[0]);
    if (when == null) return base;
    return '$base Last run: ${when.month}/${when.day} '
        '${when.hour.toString().padLeft(2, '0')}:${when.minute.toString().padLeft(2, '0')}'
        '${parts.length > 1 ? ' (${parts[1]})' : ''}';
  }

  static String _fmtBytes(int bytes) {
    if (bytes >= 1073741824) return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
    if (bytes >= 1048576) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
    return '$bytes B';
  }

  Widget _statCard(String label, String value) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            children: [
              Text(value, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}
