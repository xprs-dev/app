// The store build must never announce versions from anywhere else: F-Droid
// asked for the start-up update check to be off (fdroiddata !48456,
// 2026-10-15), and the recipe template is the one place the Android release
// build line lives (fdroiddata's recipe and release.yml both render it). A
// build line without the define would ship the notice again. docs/f-droid.md.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the F-Droid recipe template turns the start-up update check off', () {
    final text = File('fdroid/com.xprs.app.yml').readAsStringSync();
    final build = RegExp(r'flutter build apk[^\n]*(\n\s+--[^\n]*)*')
        .firstMatch(text)
        ?.group(0);
    expect(build, isNotNull, reason: 'no flutter build apk line in the recipe');
    expect(build, contains('--dart-define=AUTO_UPDATE_CHECK=false'));
  });
}
