import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'api.dart';
import 'sync_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PhotobankApp());
}

class PhotobankApp extends StatelessWidget {
  const PhotobankApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Photobank',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF4A9EFF), brightness: Brightness.dark),
        useMaterial3: true,
      ),
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
    return SyncPage(api: _api!, onLogout: _onLogout);
  }
}

class SetupPage extends StatefulWidget {
  final void Function(PhotobankApi) onLoggedIn;
  const SetupPage({super.key, required this.onLoggedIn});
  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  final _url = TextEditingController(text: 'http://192.168.');
  final _email = TextEditingController();
  final _password = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString('server_url');
      if (saved != null) _url.text = saved;
      final savedEmail = prefs.getString('email');
      if (savedEmail != null) _email.text = savedEmail;
    });
  }

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      var url = _url.text.trim();
      if (url.endsWith('/')) url = url.substring(0, url.length - 1);
      if (!url.startsWith('http')) url = 'http://$url';
      final api = PhotobankApi(baseUrl: url);
      await api.checkHealth();
      await api.login(_email.text.trim(), _password.text);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('server_url', url);
      await prefs.setString('email', _email.text.trim());
      await prefs.setString('token', api.token!);
      widget.onLoggedIn(api);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Cannot reach server - check the URL and that '
          'your phone is on the same Wi-Fi.');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('📷', textAlign: TextAlign.center, style: TextStyle(fontSize: 56)),
                const SizedBox(height: 8),
                Text('Photobank', textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 24),
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
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(labelText: 'Email', border: OutlineInputBorder()),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password', border: OutlineInputBorder()),
                  onSubmitted: (_) => _connect(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _busy ? null : _connect,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(_busy ? 'Connecting…' : 'Connect'),
                  ),
                ),
              ],
            ),
          ),
        ),
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
  bool _syncing = false;
  bool _permissionDenied = false;
  String? _lastResult;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _service.init();
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
    try {
      SyncProgress? last;
      await for (final p in _service.sync()) {
        last = p;
        if (mounted) setState(() => _progress = p);
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
                          value: _progress!.total == 0 ? null : _progress!.done / _progress!.total,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${_progress!.done} / ${_progress!.total} - ${_progress!.currentName}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          onPressed: () => _service.cancelRequested = true,
                          child: const Text('Stop'),
                        ),
                      ] else ...[
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
                      ],
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
