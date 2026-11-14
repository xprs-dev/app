// F-Droid asked for the start-up update check to be off in the APK it ships
// (fdroiddata !48456, 2026-10-15). The define now keeps automatic updates off
// where Android names no installer (adb, the reviewer's case); an F-Droid
// client install has them off regardless (defaultAutoUpdate). The recipe
// template is the one place the Android release build line lives
// (fdroiddata's recipe and release.yml both render it). docs/updates.md 6.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the F-Droid recipe template passes AUTO_UPDATE_CHECK=false', () {
    final text = File('fdroid/com.xprs.app.yml').readAsStringSync();
    final build = RegExp(r'flutter build apk[^\n]*(\n\s+--[^\n]*)*')
        .firstMatch(text)
        ?.group(0);
    expect(build, isNotNull, reason: 'no flutter build apk line in the recipe');
    expect(build, contains('--dart-define=AUTO_UPDATE_CHECK=false'));
  });
}
