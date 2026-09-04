// Host side of `flutter drive` for integration_test/screenshots_test.dart:
// receives each takeScreenshot() and writes it where the fastlane `screenshots`
// lane picks it up.
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final dir = Directory('fastlane/screenshots/en-US')..createSync(recursive: true);
  await integrationDriver(
    onScreenshot: (String name, List<int> bytes, [Map<String, Object?>? args]) async {
      final file = File('${dir.path}/$name.png')..writeAsBytesSync(bytes);
      stdout.writeln('saved ${file.path} (${bytes.length} bytes)');
      return true;
    },
  );
}
