import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final _plugin = FlutterLocalNotificationsPlugin();

Future<void> initNotifications() async {
  try {
    await _plugin.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
        ),
      ),
    );
  } catch (_) {}
}

/// Asks the OS for permission; returns whether we may show notifications.
Future<bool> requestNotificationPermission() async {
  try {
    final ios = _plugin.resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      return await ios.requestPermissions(alert: true, badge: true, sound: true) ?? false;
    }
    final android =
        _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? true;
    }
  } catch (_) {}
  return true;
}

Future<void> showBackupPressure(int pendingCount) async {
  await _plugin.show(
    1,
    'Photos waiting for backup',
    '$pendingCount items are not backed up yet - open Photobank on your home Wi-Fi.',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'backup', 'Backup reminders',
        channelDescription: 'Reminds you when unbacked-up media piles up',
        importance: Importance.defaultImportance,
      ),
      iOS: DarwinNotificationDetails(),
    ),
  );
}
