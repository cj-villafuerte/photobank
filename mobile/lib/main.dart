import 'package:background_fetch/background_fetch.dart';
import 'package:bonsoir/bonsoir.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'accounts.dart';
import 'api.dart';
import 'background.dart';
import 'albums_page.dart';
import 'library_page.dart';
import 'notifications.dart';
import 'onboarding_page.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'sync_service.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // decoded thumbnails live in RAM only; keep that bounded on a phone
  PaintingBinding.instance.imageCache.maximumSizeBytes = 64 << 20;
  PaintingBinding.instance.imageCache.maximumSize = 600;
  runApp(const PhotobankApp());
  initNotifications();
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
      debugShowCheckedModeBanner: false,
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
      // is this the public demo server? (adapts the UI) - best effort, never blocks long
      try {
        await _api!.checkHealth().timeout(const Duration(seconds: 3));
      } catch (_) {}
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
  // Bumped when the server library changed under us (a backup uploaded something) or
  // the Library tab is reopened after a while; LibraryPage re-reads on every bump.
  final _libraryRefresh = ValueNotifier<int>(0);
  DateTime _libraryFresh = DateTime.now();
  // search lives inside the Library tab: the app bar turns into a search field
  bool _searchOpen = false;
  final _searchCtrl = TextEditingController();
  String _query = '';

  void _touchLibrary() {
    _libraryFresh = DateTime.now();
    _libraryRefresh.value++;
  }

  void _toggleSearch() {
    setState(() {
      _searchOpen = !_searchOpen;
      if (!_searchOpen) {
        _searchCtrl.clear();
        _query = '';
      }
    });
  }

  @override
  void dispose() {
    _libraryRefresh.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // first sign-in on this phone: show the tour once
    OnboardingPage.isDone().then((done) {
      if (!done && mounted) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => const OnboardingPage(), fullscreenDialog: true));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          SyncPage(api: widget.api, onLogout: widget.onLogout, onLibraryChanged: _touchLibrary),
          Scaffold(
            appBar: AppBar(
              title: _searchOpen
                  ? TextField(
                      controller: _searchCtrl,
                      autofocus: true,
                      autocorrect: false,
                      textInputAction: TextInputAction.search,
                      decoration: const InputDecoration(
                        hintText: 'Search text in your photos…',
                        border: InputBorder.none,
                      ),
                      onChanged: (v) => setState(() => _query = v),
                    )
                  : const Text('Library'),
              actions: [
                IconButton(
                  icon: Icon(_searchOpen ? Icons.close : Icons.search),
                  tooltip: _searchOpen ? 'Close search' : 'Search',
                  onPressed: _toggleSearch,
                ),
                if (!_searchOpen)
                  IconButton(
                    icon: const Icon(Icons.photo_album_outlined),
                    tooltip: 'Albums',
                    onPressed: () => Navigator.push(
                        context, MaterialPageRoute(builder: (_) => AlbumsPage(api: widget.api))),
                  ),
              ],
            ),
            // the grid keeps its scroll position and state under the search results
            body: Stack(
              children: [
                Offstage(
                  offstage: _searchOpen,
                  child: LibraryPage(api: widget.api, refresh: _libraryRefresh),
                ),
                if (_searchOpen) LibrarySearch(api: widget.api, query: _query),
              ],
            ),
          ),
          SettingsPage(api: widget.api, onLogout: widget.onLogout),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        onDestinationSelected: (i) {
          if (i == 1 && _tab != 1 && DateTime.now().difference(_libraryFresh) > const Duration(minutes: 2)) {
            _touchLibrary(); // coming back to the library after a while: pick up what changed
          }
          setState(() => _tab = i);
        },
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
  final Set<String> _resolving = {}; // seen on the network, address not resolved yet
  BonsoirDiscovery? _discovery;
  bool _manual = false;
  final _url = TextEditingController();
  List<SavedAccount> _savedServers = []; // one entry per server, most recent first

  @override
  void initState() {
    super.initState();
    _startDiscovery();
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString('server_url');
      if (saved != null) _url.text = saved;
    });
    SavedAccounts.servers().then((s) {
      if (mounted) setState(() => _savedServers = s);
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
          setState(() => _resolving.add(service.name));
          service.resolve(discovery.serviceResolver);
        } else if (event.type == BonsoirDiscoveryEventType.discoveryServiceResolveFailed) {
          setState(() => _resolving.remove(service.name));
        } else if (event.type == BonsoirDiscoveryEventType.discoveryServiceResolved) {
          _resolving.remove(service.name);
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
          setState(() {
            _found.remove(service.name);
            _resolving.remove(service.name);
          });
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
                // wordmark: display 800 with the accent period
                Text.rich(
                  TextSpan(
                    text: 'Photobank',
                    style: pbDisplay(size: 40, weight: FontWeight.w800),
                    children: [TextSpan(text: '.', style: pbDisplay(size: 40, weight: FontWeight.w800, color: PbColors.accent))],
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text('BY CJ VILLAFUERTE', textAlign: TextAlign.center, style: pbMono(size: 10)),
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
                        _resolving.isEmpty
                            ? 'No servers found yet. Make sure Photobank is open on your computer '
                              'and this phone is on the same Wi-Fi.'
                            : 'Found ${_resolving.length} server${_resolving.length == 1 ? '' : 's'} '
                              '(${_resolving.join(', ')}) - connecting…\n'
                              'If this never completes, use Advanced below.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                for (final s in servers)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.computer),
                      title: Text(s.name),
                      subtitle: const Text('On this Wi-Fi'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _loginTo(s.url, s.name),
                    ),
                  ),
                // servers this phone has signed in to before - one tap, even when
                // discovery is slow or the server is somewhere else (VPN)
                for (final s in _savedServers)
                  if (!servers.any((f) => SavedAccounts.normalize(f.url) == s.server) && s.server != demoServerUrl)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.history),
                        title: Text(s.displayName),
                        subtitle: Text(s.email),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _loginTo(s.server, s.displayName),
                      ),
                    ),
                const SizedBox(height: 12),
                // no server yet? the public demo shows what the app does
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.explore_outlined),
                    title: const Text('Try the demo'),
                    subtitle: const Text('A public sample library - nothing on this phone is changed'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _loginTo(demoServerUrl, 'the demo server'),
                  ),
                ),
                const SizedBox(height: 20),
                // the address is for people who know what one is; everyone else taps a card
                if (!_manual)
                  TextButton.icon(
                    onPressed: () => setState(() => _manual = true),
                    icon: const Icon(Icons.tune, size: 18),
                    label: const Text('Advanced'),
                  )
                else ...[
                  Text('ADVANCED', style: pbMono(size: 10)),
                  const SizedBox(height: 6),
                  Text(
                    'Connect by address - it is shown in the Console of the Photobank app on your '
                    'computer, or use your own domain / VPN address.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Server address',
                      hintText: 'https://photos.example.com',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () => _loginTo(_normalizedManualUrl(), Uri.tryParse(_normalizedManualUrl())?.host ?? _normalizedManualUrl()),
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
  bool _remember = true;
  List<SavedAccount> _saved = []; // accounts used on this server before

  bool get _isDemo => widget.api.demo != null;

  @override
  void initState() {
    super.initState();
    final demo = widget.api.demo;
    if (demo != null) {
      // public demo server: the shared account is the only account
      _email.text = demo.email;
      _password.text = demo.password;
      return;
    }
    SharedPreferences.getInstance().then((prefs) {
      final saved = prefs.getString('email');
      if (saved != null && mounted && _email.text.isEmpty) setState(() => _email.text = saved);
    });
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    final list = await SavedAccounts.forServer(widget.api.baseUrl);
    if (!mounted) return;
    setState(() {
      _saved = list;
      if (list.isNotEmpty && !list.first.hasToken) _email.text = list.first.email;
    });
  }

  Future<void> _rememberCurrent(String email) async {
    if (!_remember || _isDemo || widget.api.token == null) return;
    await SavedAccounts.remember(SavedAccount(
      server: SavedAccounts.normalize(widget.api.baseUrl),
      name: widget.serverLabel,
      email: email,
      token: widget.api.token!,
      usedAt: DateTime.now(),
    ));
  }

  Future<void> _login() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final email = _email.text.trim();
      await widget.api.login(email, _password.text);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('email', email);
      await _rememberCurrent(email);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Login failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Tap a saved account: reuse its token if the server still accepts it,
  /// otherwise fall back to the password with the email filled in.
  Future<void> _useSaved(SavedAccount account) async {
    if (!account.hasToken) {
      setState(() {
        _email.text = account.email;
        _error = 'Session expired - enter the password for ${account.email}';
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    widget.api.token = account.token;
    try {
      await widget.api.me(); // proves the token is still good
      await SavedAccounts.remember(account.copyWith(usedAt: DateTime.now()));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('email', account.email);
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      widget.api.token = null;
      if (e.status == 401 || e.status == 403) {
        await SavedAccounts.invalidateToken(account.server, account.email);
        await _loadSaved();
        if (mounted) {
          setState(() {
            _email.text = account.email;
            _error = 'Session expired - enter the password for ${account.email}';
          });
        }
      } else if (mounted) {
        setState(() => _error = e.message);
      }
    } catch (e) {
      widget.api.token = null;
      if (mounted) setState(() => _error = 'Could not sign in: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forget(SavedAccount account) async {
    await SavedAccounts.forget(account.server, account.email);
    await _loadSaved();
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
          if (widget.api.demo != null) ...[
            const SizedBox(height: 8),
            Text(
              'Public demo server - the shared account is filled in. The sample library is '
              'read-only and uploads are removed after a few seconds.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          if (_saved.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text('SAVED ON THIS PHONE', style: pbMono(size: 10)),
            const SizedBox(height: 4),
            for (final a in _saved)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(child: Text(a.initial)),
                title: Text(a.email),
                subtitle: Text(a.hasToken ? 'Tap to continue' : 'Password needed'),
                trailing: IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Forget this account',
                  onPressed: _busy ? null : () => _forget(a),
                ),
                onTap: _busy ? null : () => _useSaved(a),
              ),
            const SizedBox(height: 6),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text('OR SIGN IN', style: pbMono(size: 10)),
                ),
                const Expanded(child: Divider()),
              ],
            ),
          ],
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
          if (!_isDemo)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Remember me on this phone'),
              subtitle: const Text('Keeps the sign-in (not the password) in the Keychain'),
              value: _remember,
              onChanged: (v) => setState(() => _remember = v ?? true),
            ),
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
  final VoidCallback? onLibraryChanged; // a backup put new items on the server
  const SyncPage({super.key, required this.api, required this.onLogout, this.onLibraryChanged});
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
  int _retentionCandidates = 0;
  int _retentionMonths = 2;
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
    // the keep window applies to the Free up space button regardless of the
    // automatic toggle; the reminder card only shows when automatic is on
    final months = prefs.getInt('retention_months') ?? 2;
    var candidates = 0;
    if (prefs.getBool('retention_enabled') ?? false) {
      candidates = (await _service.retentionCandidates(months)).length;
    }
    if (mounted) {
      setState(() {
        _retentionMonths = months;
        _retentionCandidates = candidates;
      });
    }
  }

  Future<void> _applyRetention() async {
    try {
      final n = await _service.applyRetention(_retentionMonths);
      _lastResult = n > 0
          ? 'Removed $n backed-up items older than $_retentionMonths months from this phone.'
          : 'Nothing eligible right now.';
    } catch (e) {
      _lastResult = 'Could not apply retention: $e';
    }
    await _load();
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
      if (last != null && last.total > 0) {
        _lastResult = _service.cancelRequested
            ? 'Sync stopped - ${last.uploaded} uploaded before stopping.'
            : 'Done: ${last.uploaded} uploaded, ${last.skipped} already backed up'
              '${last.failed > 0 ? ', ${last.failed} failed' : ''}.';
        if (last.uploaded > 0) widget.onLibraryChanged?.call(); // the Library tab re-reads
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
    // the keep window is a setting (Settings > Phone storage); just confirm
    final months = _retentionMonths;
    final before = months == 0 ? null : DateTime.now().subtract(Duration(days: 30 * months));
    final count = (await _service.backedUp(before: before)).length;
    if (!mounted) return;
    if (count == 0) {
      setState(() => _lastResult = months == 0
          ? 'Nothing backed up to remove.'
          : 'No backed-up items older than $months month${months == 1 ? '' : 's'}.');
      return;
    }
    final dateText = before == null
        ? ''
        : ' taken before ${before.month}/${before.day}/${before.year}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Free up space?'),
        content: Text(
          'This will delete $count backed-up photo${count == 1 ? '' : 's'}/video'
          '${count == 1 ? '' : 's'}$dateText from this phone'
          '${months == 0 ? '' : ' (keeping the last $months month${months == 1 ? '' : 's'})'}. '
          'Each is verified on the server first, and iOS will ask you to confirm.\n\n'
          'Change the window in Settings > Phone storage.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Delete $count')),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final n = await _service.freeUpSpace(before: before);
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
    // while a backup runs, count what has already landed instead of waiting for the end
    final progress = _progress;
    final live = (stats != null && _syncing && progress != null)
        ? DeviceStats(stats.totalOnDevice,
            (stats.backedUp + progress.uploaded + progress.skipped).clamp(0, stats.totalOnDevice).toInt())
        : stats;
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
                      Text('01  BACKUP', style: pbMono(size: 11)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _statCard('On this phone', '${live!.totalOnDevice}'),
                          const SizedBox(width: 12),
                          _statCard('Backed up', '${live.backedUp}'),
                          const SizedBox(width: 12),
                          _statCard('To sync', '${live.pending}'),
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
                            child: Text(widget.api.demo != null
                                ? 'Try a backup (newest 25 photos)'
                                : stats.pending == 0
                                    ? 'Everything is backed up'
                                    : 'Back up ${stats.pending} items'),
                          ),
                        ),
                        if (widget.api.demo == null) ...[
                          const SizedBox(height: 12),
                          OutlinedButton.icon(
                            onPressed: stats.backedUp == 0 ? null : _freeUpSpace,
                            icon: const Icon(Icons.cleaning_services),
                            label: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text(_retentionMonths == 0
                                  ? 'Free up space (remove all ${stats.backedUp} backed up)'
                                  : 'Free up space (keep last $_retentionMonths mo)'),
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
                        ] else ...[
                          // demo server: nothing is ever removed from this phone
                          const SizedBox(height: 12),
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Text(
                                'Demo server: uploads are removed after '
                                '${widget.api.demo!.uploadTtlSeconds} seconds and the sample library is '
                                'read-only. Free up space is off - nothing is deleted from this phone.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          ),
                        ],
                      ],
                      if (!_syncing && _retentionCandidates > 0 && widget.api.demo == null) ...[
                        const SizedBox(height: 16),
                        Card(
                          child: ListTile(
                            leading: const Icon(Icons.auto_delete),
                            title: Text('$_retentionCandidates backed-up items are older than '
                                '$_retentionMonths month${_retentionMonths == 1 ? '' : 's'}'),
                            subtitle: const Text('Each is re-verified on the server before removal.'),
                            trailing: FilledButton(
                              onPressed: _applyRetention,
                              child: const Text('Remove'),
                            ),
                          ),
                        ),
                      ],
                      if (widget.api.demo == null) ...[
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
                      ],
                      if (_lastResult != null) ...[
                        const SizedBox(height: 20),
                        Card(
                          child: Padding(padding: const EdgeInsets.all(14), child: Text(_lastResult!)),
                        ),
                      ],
                      const SizedBox(height: 20),
                      Text(
                        widget.api.demo != null
                            ? 'Demo server: each backup sends the newest 25 photos; the server '
                              'removes them again shortly after. Nothing is removed from this phone.'
                            : 'Backups only run while this app is open. Photos are verified '
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
              Text(value, style: pbDisplay(size: 26)),
              const SizedBox(height: 4),
              Text(label.toUpperCase(), style: pbMono(size: 9)),
            ],
          ),
        ),
      ),
    );
  }
}
