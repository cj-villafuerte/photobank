import 'package:background_fetch/background_fetch.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api.dart';
import 'sync_service.dart';

Future<PhotobankApi?> restoreApi() async {
  final prefs = await SharedPreferences.getInstance();
  final url = prefs.getString('server_url');
  final token = prefs.getString('token');
  if (url == null || token == null) return null;
  return PhotobankApi(baseUrl: url, token: token);
}

/// Uploads as much as fits in the OS-granted background window, then stops.
Future<void> backgroundSyncSlice({Duration budget = const Duration(seconds: 22)}) async {
  final prefs = await SharedPreferences.getInstance();
  if (!(prefs.getBool('bg_backup') ?? false)) return;
  final api = await restoreApi();
  if (api == null) return;

  final perm = await PhotoManager.requestPermissionExtend();
  if (!perm.isAuth && !perm.hasAccess) return;

  final service = SyncService(api);
  await service.init();
  final deadline = DateTime.now().add(budget);
  final oldestFirst = prefs.getBool('sync_oldest_first') ?? false;
  var uploadedAny = false;
  try {
    await for (final p in service.sync(oldestFirst: oldestFirst)) {
      uploadedAny = uploadedAny || p.uploaded > 0;
      if (DateTime.now().isAfter(deadline)) service.cancelRequested = true;
    }
  } catch (_) {
    // wrong network / server asleep - try again next window
  }
  await prefs.setString('last_bg_sync',
      '${DateTime.now().toIso8601String()}|${uploadedAny ? 'uploaded' : 'nothing new'}');
}

/// Android-only: runs when the app process is dead. iOS relaunches the app
/// into the normal callback instead.
@pragma('vm:entry-point')
void backgroundFetchHeadlessTask(HeadlessEvent event) async {
  if (event.timeout) {
    BackgroundFetch.finish(event.taskId);
    return;
  }
  try {
    await backgroundSyncSlice();
  } catch (_) {}
  BackgroundFetch.finish(event.taskId);
}

/// Called once at app start; the OS keeps firing tasks even when the app
/// is closed (stopOnTerminate false). The 'bg_backup' pref gates real work.
Future<void> initBackgroundBackup() async {
  try {
    await BackgroundFetch.configure(
      BackgroundFetchConfig(
        minimumFetchInterval: 15,
        stopOnTerminate: false,
        startOnBoot: true,
        enableHeadless: true,
        requiredNetworkType: NetworkType.ANY,
      ),
      (String taskId) async {
        try {
          await backgroundSyncSlice();
        } catch (_) {}
        BackgroundFetch.finish(taskId);
      },
      (String taskId) async {
        BackgroundFetch.finish(taskId);
      },
    );
    final prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool('bg_backup') ?? false)) {
      await BackgroundFetch.stop();
    }
  } catch (_) {
    // plugin unavailable (e.g. unsupported platform) - foreground sync still works
  }
}

Future<void> setBackgroundBackupEnabled(bool enabled) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('bg_backup', enabled);
  try {
    if (enabled) {
      await BackgroundFetch.start();
    } else {
      await BackgroundFetch.stop();
    }
  } catch (_) {}
}
