// App Store screenshots: drives the real app against a Photobank server (the public
// demo by default) on an iPhone simulator and captures each main screen at device
// resolution. Run through `flutter drive` so the driver can save the PNGs - see
// .github/workflows/screenshots.yml. PB_SERVER overrides the server.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:photobank_mobile/api.dart';
import 'package:photobank_mobile/main.dart' as app;
import 'package:shared_preferences/shared_preferences.dart';

const server = String.fromEnvironment(
  'PB_SERVER',
  defaultValue: 'https://photobank-demo-production.up.railway.app',
);

/// pumpAndSettle never returns while a spinner animates; pump a fixed span instead.
Future<void> settle(WidgetTester tester, {double seconds = 3}) async {
  final frames = (seconds * 4).round();
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// Pump until [finder] shows up (photo stats on a fresh simulator can take a while).
Future<bool> waitFor(WidgetTester tester, Finder finder, {double seconds = 30}) async {
  final frames = (seconds * 4).round();
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (finder.evaluate().isNotEmpty) return true;
  }
  return false;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('App Store screenshots', (tester) async {
    // Sign in the way the app does, then start it already logged in with the tour done.
    final api = PhotobankApi(baseUrl: server);
    await api.checkHealth();
    final email = api.demo?.email ?? const String.fromEnvironment('PB_EMAIL');
    final password = api.demo?.password ?? const String.fromEnvironment('PB_PASSWORD');
    await api.login(email, password);
    SharedPreferences.setMockInitialValues({
      'server_url': server,
      'token': api.token!,
      'email': email,
      'onboarded': true,
    });

    // the workflow re-grants photo access right after `flutter drive` reinstalls the app;
    // give that a moment so no permission dialog blocks the backup screen
    await Future<void>.delayed(const Duration(seconds: 4));
    app.main();
    await waitFor(tester, find.text('Backed up')); // stat cards = photo library scanned
    await settle(tester, seconds: 2);
    await binding.takeScreenshot('01-backup');

    await tester.tap(find.text('Library'));
    await waitFor(tester, find.byType(GridView));
    await settle(tester, seconds: 8); // let the thumbnails in view finish loading
    await binding.takeScreenshot('02-library');

    // open the first photo
    final thumbs = find.descendant(of: find.byType(GridView), matching: find.byType(GestureDetector));
    if (thumbs.evaluate().isNotEmpty) {
      await tester.tap(thumbs.first);
      await settle(tester, seconds: 5);
      await binding.takeScreenshot('03-photo');
      await tester.tap(find.byTooltip('Back').first);
      await settle(tester, seconds: 2);
    }

    await tester.tap(find.byTooltip('Albums'));
    await settle(tester, seconds: 6);
    await binding.takeScreenshot('04-albums');
    await tester.tap(find.byTooltip('Back').first);
    await settle(tester, seconds: 2);

    await tester.tap(find.text('Settings'));
    await settle(tester, seconds: 3);
    await binding.takeScreenshot('05-settings');
  });
}
