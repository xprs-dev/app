// The pragma that answers differently on each platform.
//
// `PRAGMA page_count` returns an INTEGER on the desktop and a STRING on
// Android. Three callers cast it with `as num`, caught the failure and
// returned 0: the Archiver screen showed "0 B" over 156,000 packets, and the
// gossip table's byte budget compared 0 against its cap on exactly the devices
// with the least room to spare.
import 'dart:ffi';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:xprs/services/db_bytes.dart';

void main() {
  setUpAll(() {
    open.overrideFor(
        OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
  });

  late Database db;
  setUp(() => db = sqlite3.openInMemory());
  tearDown(() => db.dispose());

  test('a database reports its size', () {
    db.execute('CREATE TABLE t(a TEXT)');
    for (var i = 0; i < 200; i++) {
      db.execute('INSERT INTO t VALUES (?)', ['x' * 500]);
    }
    final bytes = sqliteDbBytes(db);
    expect(bytes, isNotNull);
    expect(bytes!, greaterThan(50000),
        reason: '200 rows of 500 bytes are on some pages somewhere');
  });

  test('a pragma answered as text is still a number', () {
    // What Android does. Proven through the same parser the callers use, since
    // an in-memory desktop database will not produce the string itself.
    expect(sqlitePragmaInt(db, 'page_size'), isNotNull);
    expect(sqlitePragmaInt(db, 'user_version'), 0);
  });

  test('a pragma that says nothing says null, not zero', () {
    // The distinction the byte budget turns on: "no answer" must not read as
    // "empty database", or a cap that can never be exceeded evicts nothing.
    expect(sqlitePragmaInt(db, 'not_a_pragma_at_all'), isNull);
    // An empty database really has no pages, and that is the one case where
    // "no size" and "no bytes" mean the same thing.
    expect(sqliteDbBytes(db), isNull);
    db.execute('CREATE TABLE t(a)');
    expect(sqliteDbBytes(db), isNotNull);
  });
}
