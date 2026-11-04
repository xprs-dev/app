/*
 * Runs before every test file. It wires the core's settings store (below),
 * and the English tables: widgets under test read their words through
 * tr(), and with no table installed a key comes back as itself, so
 * `find.text('Delete for everyone')` finds nothing. Every test therefore
 * starts with the English tables; a test about another language installs
 * its own over them.
 */
import 'dart:async';

import 'package:xprs/boot/core_stores_app.dart';
import 'package:xprs_core/src/platform/core_host.dart';

import 'i18n_english.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // PreferencesService opens its store through the core's seam; the app's
  // tests seed shared_preferences (SharedPreferences.setMockInitialValues),
  // so they get the app's shared_preferences-backed store, as the app does.
  CoreHost.openPreferences = SharedPreferencesStore.open;
  // Translations load from the Flutter asset bundle, as in the app.
  CoreHost.assets = const BundleAssets();
  installEnglishForTest();
  await testMain();
}
