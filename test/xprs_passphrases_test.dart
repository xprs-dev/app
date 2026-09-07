/*
 * The remembered-passphrase store (docs/XPRS.md 9.2.1): passphrases that opened
 * redacted text survive a restart and come back most-recently-used first, so a
 * tap can try them before prompting. A restart is close() + a fresh init().
 */
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/xprs/xprs_passphrases.dart';

void main() {
  late Directory tmp;
  late String path;

  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xprspass');
    path = '${tmp.path}/xprs_passphrases.sqlite3';
    XprsPassphrases.instance.init(path);
  });

  tearDown(() {
    XprsPassphrases.instance.close();
    tmp.deleteSync(recursive: true);
  });

  test('a remembered passphrase survives a restart', () {
    XprsPassphrases.instance.remember('hunter2');
    XprsPassphrases.instance.close();
    XprsPassphrases.instance.init(path); // restart
    expect(XprsPassphrases.instance.all(), contains('hunter2'));
  });

  test('most-recently-used comes first', () {
    final p = XprsPassphrases.instance;
    p.remember('first', nowMs: 1000);
    p.remember('second', nowMs: 2000);
    p.remember('first', nowMs: 3000); // reused, jumps to front
    expect(p.all(), ['first', 'second']);
  });

  test('most-used comes first, recency breaks ties', () {
    final p = XprsPassphrases.instance;
    p.remember('rare', nowMs: 5000);        // used once, most recent
    p.remember('common', nowMs: 1000);      // used
    p.remember('common', nowMs: 2000);      // ...twice -> higher count
    expect(p.all().first, 'common');        // count beats recency
  });

  test('remembering is idempotent (no duplicate rows)', () {
    final p = XprsPassphrases.instance;
    p.remember('same');
    p.remember('same');
    expect(p.all().where((s) => s == 'same').length, 1);
  });

  test('the empty passphrase is never stored', () {
    XprsPassphrases.instance.remember('');
    expect(XprsPassphrases.instance.all(), isEmpty);
  });

  test('forget removes one', () {
    final p = XprsPassphrases.instance;
    p.remember('a');
    p.remember('b');
    p.forget('a');
    expect(p.all(), ['b']);
  });
}
