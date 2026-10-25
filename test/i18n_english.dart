/*
 * English tables for widget tests.
 *
 * A widget under test reads its words through tr(); with nothing loaded a
 * key comes back as itself and `find.text('Today')` finds nothing. The real
 * loader reads the asset bundle, which a plain `flutter test` does not have,
 * so this reads the English JSON files from disk and installs them. Call
 * [installEnglishForTest] once in main(), before the first pump.
 */
import 'dart:convert';
import 'dart:io';

import 'package:xprs/services/i18n/core_i18n.dart';
import 'package:xprs/services/i18n/i18n_context.dart';

void installEnglishForTest() {
  final table = <String, String>{};
  final dir = Directory('assets/lang/en');
  for (final f in dir.listSync().whereType<File>()) {
    if (!f.path.endsWith('.json')) continue;
    final j = jsonDecode(f.readAsStringSync()) as Map;
    for (final e in j.entries) {
      if (e.value is String) table[e.key as String] = e.value as String;
    }
  }
  CoreI18n.instance.installForTest(
      I18nContext(locale: 'en', primary: table, fallback: const {}),
      languages: const ['en']);
}
