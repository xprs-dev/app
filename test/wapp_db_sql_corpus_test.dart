// Every SQL statement the chat and circles wapps send through hal_db_* (the
// literal ones, macros resolved: tool/wapp_sql_corpus.py) compiles on zx, the
// engine behind hal.db. A statement the wapps rely on and zx cannot run would
// otherwise surface only on a phone, as a wapp that silently stores nothing.
//
// Regenerate the fixture after changing a wapp's SQL:
//   cd ../apps && python3 ../app/tool/wapp_sql_corpus.py \
//       ../app/test/fixtures/wapp_sql_corpus.json chat/*.c circles/*.c
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs_core/src/storage/store_db.dart' show openMemoryStoreDb;

void main() {
  final corpus = (jsonDecode(
          File('test/fixtures/wapp_sql_corpus.json').readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();

  bool isSchema(String sql) =>
      RegExp(r'^\s*(CREATE|DROP|ALTER)\b', caseSensitive: false).hasMatch(sql);

  for (final wapp in ['chat', 'circles']) {
    test('$wapp: every statement compiles on zx', () {
      final mine =
          corpus.where((s) => (s['file'] as String).startsWith('$wapp/'));
      expect(mine, isNotEmpty);
      final db = openMemoryStoreDb();
      final failures = <String>[];
      // The schema first (every database of the wapp in one: the table
      // names do not collide), then everything else against it.
      for (final s in mine.where((s) => isSchema(s['sql'] as String))) {
        try {
          db.execute(s['sql'] as String);
        } catch (e) {
          // An upgrade ladder's ADD COLUMN for a column the CREATE already
          // has: zx refuses it, and the wapp ignores it.
          if ('$e'.contains('duplicate column name')) continue;
          failures.add('${s['file']}: ${s['sql']}\n  -> $e');
        }
      }
      for (final s in mine.where((s) => !isSchema(s['sql'] as String))) {
        try {
          db.prepare(s['sql'] as String).dispose();
        } catch (e) {
          failures.add('${s['file']}: ${s['sql']}\n  -> $e');
        }
      }
      db.dispose();
      expect(failures, isEmpty, reason: failures.join('\n'));
    });
  }
}
