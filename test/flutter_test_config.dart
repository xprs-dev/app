/*
 * Runs before every test file: widgets under test read their words through
 * tr(), and with no table installed a key comes back as itself, so
 * `find.text('Delete for everyone')` finds nothing. Every test therefore
 * starts with the English tables; a test about another language installs
 * its own over them.
 */
import 'dart:async';

import 'i18n_english.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  installEnglishForTest();
  await testMain();
}
