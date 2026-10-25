/*
 * The core's translations: the resolver's rules, and the shape of the files
 * that ship. tool/i18n_check.dart checks the code against the files; this
 * checks what the tool cannot — tr()'s behaviour — and that every language
 * folder a build ships parses and mirrors English file for file.
 */
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/i18n/core_i18n.dart';
import 'package:xprs/services/i18n/i18n_context.dart';
import 'package:xprs/services/i18n/format.dart';
import 'package:xprs/services/i18n/schedule_text.dart';
import 'package:reticulum/src/services/social/listening_schedule.dart';

void main() {
  group('tr()', () {
    setUp(() {
      CoreI18n.instance.installForTest(const I18nContext(
        locale: 'pt_PT',
        primary: {
          'settings.hosting.title': 'Alojamento',
          'settings.muted.count.one': '{n} conta',
          'settings.muted.count.other': '{n} contas',
        },
        fallback: {
          'settings.hosting.title': 'Hosting',
          'settings.remote.title': 'Remote control',
          'settings.remote.listening': 'Listening on 127.0.0.1:{port}',
          'settings.muted.count.one': '{n} account',
          'settings.muted.count.other': '{n} accounts',
        },
      ));
    });

    test('primary first, then English, then the key itself', () {
      expect(tr('settings.hosting.title'), 'Alojamento');
      expect(tr('settings.remote.title'), 'Remote control');
      expect(tr('settings.nowhere'), 'settings.nowhere');
    });

    test('placeholders are filled, and left alone when not given', () {
      expect(tr('settings.remote.listening', {'port': 3456}),
          'Listening on 127.0.0.1:3456');
      expect(tr('settings.remote.listening'), 'Listening on 127.0.0.1:{port}');
    });

    test('plurals pick .one for exactly one', () {
      expect(trn('settings.muted.count', 1), '1 conta');
      expect(trn('settings.muted.count', 0), '0 contas');
      expect(trn('settings.muted.count', 7), '7 contas');
    });

    test('a language tag becomes a Flutter Locale', () {
      CoreI18n.instance.installForTest(
          const I18nContext(locale: 'pt_PT', primary: {}, fallback: {}),
          languages: ['en', 'pt', 'es']);
      expect(CoreI18n.instance.flutterLocale.languageCode, 'pt');
      expect(CoreI18n.instance.flutterLocale.countryCode, 'PT');
      expect(CoreI18n.instance.supportedLocales.map((l) => l.languageCode),
          ['en', 'pt', 'es']);
    });
  });

  group('sizes and schedules', () {
    void install(String code) {
      Map<String, String> folder(String c) {
        final out = <String, String>{};
        for (final f in Directory('assets/lang/$c').listSync().whereType<File>()) {
          final j = jsonDecode(f.readAsStringSync()) as Map;
          for (final e in j.entries) {
            if (e.value is String) out[e.key as String] = e.value as String;
          }
        }
        return out;
      }

      CoreI18n.instance.installForTest(I18nContext(
          locale: code, primary: folder(code), fallback: folder('en')));
    }

    test('bytes use the language\'s unit names and decimal mark', () {
      install('en');
      expect(trBytes(512), '512 B');
      expect(trBytes(1536), '1.5 KB');
      expect(trBytes(3 << 30, gbDigits: 2), '3.00 GB');
      install('fr');
      expect(trBytes(1536), '1,5 Ko');
      expect(trBytes(5 << 20), '5,0 Mo');
      install('de');
      expect(trBytes(1536), '1,5 KB');
    });

    test('a schedule reads in the language, term for term', () {
      final s = ListeningSchedule.parse('every 30m for 3m, 18:00-22:00 weekends');
      install('en');
      // The library's sentence, with the day names written out.
      expect(trSchedule(s),
          'wakes for 3m every 30m (10% of the time); or from 18:00 to 22:00 '
          'UTC, Saturday, Sunday.');
      expect(describeSchedule(s), contains('wakes for 3m every 30m'));
      install('pt');
      final pt = trSchedule(s);
      expect(pt, contains('acorda 3m a cada 30m'));
      expect(pt, contains('sábado, domingo'));
      install('en');
      expect(trSchedule(ListeningSchedule.parse('always')),
          'Listening all the time.');
    });
  });

  group('assets/lang', () {
    final root = Directory('assets/lang');
    final en = Directory('${root.path}/en');

    Map<String, String> load(File f) {
      final j = jsonDecode(f.readAsStringSync()) as Map;
      return {
        for (final e in j.entries)
          if (e.key != '_meta') e.key as String: e.value as String,
      };
    }

    test('every language ships the same files as English, same keys', () {
      expect(en.existsSync(), isTrue);
      final enFiles = en
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .toList();
      expect(enFiles, isNotEmpty);
      for (final d in root.listSync().whereType<Directory>()) {
        final code = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
        for (final ef in enFiles) {
          final name = ef.uri.pathSegments.last;
          final f = File('${d.path}/$name');
          expect(f.existsSync(), isTrue, reason: '$code lacks $name');
          final a = load(ef).keys.toSet();
          final b = load(f).keys.toSet();
          expect(b, a, reason: '$code/$name differs from English in keys');
        }
      }
    });

    test('a key lives in the file its first segment names', () {
      for (final f in en.listSync().whereType<File>()) {
        final area = f.uri.pathSegments.last.replaceAll('.json', '');
        for (final k in load(f).keys) {
          expect(k.split('.').first, area, reason: '$k in $area.json');
        }
      }
    });

    test('placeholders match English in every translation', () {
      final ph = RegExp(r'\{[a-z_]+\}');
      final enAll = <String, String>{};
      for (final f in en.listSync().whereType<File>()) {
        enAll.addAll(load(f));
      }
      for (final d in root.listSync().whereType<Directory>()) {
        for (final f in d.listSync().whereType<File>()) {
          for (final e in load(f).entries) {
            final want = ph.allMatches(enAll[e.key] ?? '').map((m) => m[0]).toSet();
            final have = ph.allMatches(e.value).map((m) => m[0]).toSet();
            expect(have, want, reason: '${f.path}: ${e.key}');
          }
        }
      }
    });
  });
}
