/*
 * What opening hidden text COSTS (XPRS.md 6.2.1).
 *
 * The price of one derivation is the spec's and is not tested here; the number
 * of derivations is ours, and is. A tap used to pay for the whole remembered
 * list -- up to 201 of them, each 100000 iterations -- to open one message,
 * and paid again every time the same message was tapped.
 *
 * Counters, not a stopwatch: a clock measures the machine, a count measures
 * the decision (docs/performance.md §4).
 */
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/reticulum.dart' show XprsCrypto;
import 'package:sqlite3/open.dart';
import 'package:xprs/services/xprs/xprs_passphrases.dart';
import 'package:xprs/services/xprs/xprs_redaction.dart';

void main() {
  late Directory tmp;

  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('xprsredact');
    XprsPassphrases.instance.init('${tmp.path}/xprs_passphrases.sqlite3');
    XprsRedaction.instance.resetForTest();
  });

  tearDown(() {
    XprsPassphrases.instance.close();
    tmp.deleteSync(recursive: true);
  });

  const dflt = XprsCrypto.kXrDefaultPassphrase;

  group('the order candidates are tried in', () {
    test('the default comes before the remembered ones', () {
      // 6.2.1 makes the default the common case, and it is public anyway, so
      // trying it early costs nobody anything and saves the usual message a
      // sweep through everything else.
      XprsPassphrases.instance.remember('hunter2');
      XprsPassphrases.instance.remember('correct horse');
      final c = XprsRedaction.instance.candidates('X1WATT');
      expect(c.first, dflt);
      expect(c, containsAll(<String>['hunter2', 'correct horse']));
    });

    test('what last opened a message from this sender comes first of all', () {
      XprsPassphrases.instance.remember('hunter2');
      XprsPassphrases.instance.remember('other');
      XprsPassphrases.instance.hint('X1WATT', 'hunter2');
      expect(XprsRedaction.instance.candidates('X1WATT').first, 'hunter2');
      // ...and only for that sender.
      expect(XprsRedaction.instance.candidates('X1ANNA').first, dflt);
    });

    test('a hint is not repeated further down the list', () {
      XprsPassphrases.instance.remember('hunter2');
      XprsPassphrases.instance.hint('X1WATT', 'hunter2');
      final c = XprsRedaction.instance.candidates('X1WATT');
      expect(c.where((p) => p == 'hunter2').length, 1);
    });

    test('an unknown sender still gets every passphrase, just later', () {
      for (final p in ['a', 'b', 'c']) {
        XprsPassphrases.instance.remember(p);
      }
      final c = XprsRedaction.instance.candidates('');
      expect(c.first, dflt);
      expect(c.length, 4);
    });
  });

  group('the passphrase store', () {
    test('a hint survives a restart, like the passphrase it names', () {
      XprsPassphrases.instance.hint('X1WATT', 'hunter2');
      XprsPassphrases.instance.close();
      XprsPassphrases.instance.init('${tmp.path}/xprs_passphrases.sqlite3');
      expect(XprsPassphrases.instance.hintFor('X1WATT'), 'hunter2');
      // Callsigns are compared upper case however they were written.
      expect(XprsPassphrases.instance.hintFor('x1watt'), 'hunter2');
    });

    test('an opened message is kept, and answered without a derivation', () {
      XprsPassphrases.instance.cacheOpened('ab12cd', 'meet Max', 'hunter2');
      XprsPassphrases.instance.close();
      XprsPassphrases.instance.init('${tmp.path}/xprs_passphrases.sqlite3');
      expect(XprsPassphrases.instance.opened('ab12cd'), 'meet Max');
      expect(XprsPassphrases.instance.opened('nothing'), isNull);
    });

    test('forgetting a passphrase forgets what it opened', () {
      // Otherwise "forget" would be a lie: the plaintext would outlive the key
      // that produced it.
      XprsPassphrases.instance.remember('hunter2');
      XprsPassphrases.instance.hint('X1WATT', 'hunter2');
      XprsPassphrases.instance.cacheOpened('ab12cd', 'meet Max', 'hunter2');
      XprsPassphrases.instance.forget('hunter2');
      expect(XprsPassphrases.instance.all(), isEmpty);
      expect(XprsPassphrases.instance.opened('ab12cd'), isNull);
      expect(XprsPassphrases.instance.hintFor('X1WATT'), isNull);
    });

    test('learning or forgetting a passphrase moves the generation', () {
      // The miss cache is only allowed to believe itself while this holds.
      final g0 = XprsPassphrases.instance.generation;
      XprsPassphrases.instance.remember('hunter2');
      final g1 = XprsPassphrases.instance.generation;
      expect(g1, greaterThan(g0));
      XprsPassphrases.instance.forget('hunter2');
      expect(XprsPassphrases.instance.generation, greaterThan(g1));
    });
  });

  group('the author does not pay to read their own message', () {
    test('the marks come out exactly as redact reads them', () {
      // Not a bracket-strip: the same walk redact does, so the author's bubble
      // cannot disagree with what the recipients see.
      expect(XprsRedaction.plainOf('meet ((Max)) at ((pier2))'),
          'meet Max at pier2');
      expect(XprsRedaction.plainOf('nothing marked'), 'nothing marked');
      // An unclosed mark is left exactly as typed, as redact leaves it.
      expect(XprsRedaction.plainOf('a ((b'), 'a ((b');
      expect(XprsRedaction.plainOf('((a)) then ((b'), 'a then ((b');
    });

    test('what it caches is what restore would hand back', () {
      const authored = 'code is ((swordfish)) tonight';
      final red = XprsCrypto.redact(authored, passphrase: 'hunter2')!;
      final restored = XprsCrypto.restore(red.$1, red.$2, 'hunter2');
      expect(restored, XprsRedaction.plainOf(authored));
    });
  });
}
