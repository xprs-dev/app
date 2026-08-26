// Tests for the update mirror's decision-making. Pure Dart: no RNS, no
// network, no DownloadManager — those need two nodes and a device and belong
// with tool/update_net_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/update_mirror_service.dart';
import 'package:xprs/services/update_models.dart';

/// The four artifacts a release publishes, named the way CI names them.
List<String> _release(String v) => [
      'xprs-$v-android-arm64-v8a.apk',
      'xprs-$v-android-armeabi-v7a.apk',
      'xprs-$v-android-x86_64.apk',
      'xprs-$v-linux-x64.tar.gz',
    ];

void main() {
  group('mirrorPruneVictims', () {
    test('keeps the newest 5 versions and drops every file of the rest', () {
      final held = <String>[
        for (final v in [
          '1.0.0',
          '1.1.0',
          '1.2.0',
          '1.3.0',
          '1.4.0',
          '1.5.0',
          '1.6.0',
        ])
          ..._release(v),
      ];
      final victims = mirrorPruneVictims(held, keep: 5);

      // The two oldest versions go, whole: 2 x 4 files.
      expect(victims.length, 8);
      for (final v in ['1.0.0', '1.1.0']) {
        for (final n in _release(v)) {
          expect(victims, contains(n), reason: '$n should be pruned');
        }
      }
      // Nothing from a kept version is ever a victim.
      for (final v in ['1.2.0', '1.3.0', '1.4.0', '1.5.0', '1.6.0']) {
        for (final n in _release(v)) {
          expect(victims, isNot(contains(n)), reason: '$n must be kept');
        }
      }
    });

    test('fewer versions than the limit prunes nothing', () {
      final held = [..._release('1.0.0'), ..._release('1.1.0')];
      expect(mirrorPruneVictims(held, keep: 5), isEmpty);
    });

    test('exactly the limit prunes nothing', () {
      final held = [
        for (final v in ['1.0.0', '1.1.0', '1.2.0', '1.3.0', '1.4.0'])
          ..._release(v),
      ];
      expect(mirrorPruneVictims(held, keep: 5), isEmpty);
    });

    test('prereleases order below their release, and among themselves', () {
      // Six versions, keep 3: 1.2.0 > 1.2.0-beta.2 > 1.2.0-beta.1 > 1.1.0 ...
      final held = <String>[
        for (final v in [
          '1.0.0',
          '1.1.0',
          '1.2.0-beta.1',
          '1.2.0-beta.2',
          '1.2.0',
        ])
          ..._release(v),
      ];
      final victims = mirrorPruneVictims(held, keep: 3);
      // Kept: 1.2.0, 1.2.0-beta.2, 1.2.0-beta.1. Pruned: 1.1.0 and 1.0.0.
      expect(victims.length, 8);
      expect(victims, contains('xprs-1.1.0-android-x86_64.apk'));
      expect(victims, contains('xprs-1.0.0-android-x86_64.apk'));
      expect(
          victims, isNot(contains('xprs-1.2.0-beta.1-android-x86_64.apk')));
    });

    test('a file whose version cannot be parsed is never deleted', () {
      // A mirror must not delete what it does not understand: .folder.json
      // holds the folder's MASTER KEY, and deleting it would orphan the folder.
      final held = <String>[
        for (final v in ['1.0.0', '1.1.0', '1.2.0', '1.3.0', '1.4.0', '1.5.0'])
          ..._release(v),
        '.folder.json',
        'README.md',
        'some-other-project-2.0.0.apk',
      ];
      final victims = mirrorPruneVictims(held, keep: 5);
      expect(victims, isNot(contains('.folder.json')));
      expect(victims, isNot(contains('README.md')));
      expect(victims, isNot(contains('some-other-project-2.0.0.apk')));
      // Only the one expired version's files.
      expect(victims.length, 4);
    });

    test('a version missing a platform still survives whole', () {
      final held = <String>[
        'xprs-1.0.0-android-arm64-v8a.apk', // older, incomplete
        for (final v in ['1.1.0', '1.2.0', '1.3.0', '1.4.0', '1.5.0'])
          ..._release(v),
      ];
      final victims = mirrorPruneVictims(held, keep: 5);
      expect(victims, ['xprs-1.0.0-android-arm64-v8a.apk']);
    });

    test('empty input', () {
      expect(mirrorPruneVictims(const <String>[], keep: 5), isEmpty);
    });
  });

  group('CI artifact names parse back to their version', () {
    test('every platform the release workflow publishes', () {
      const v = '1.2.0-beta.1';
      expect(versionFromAssetName('xprs-$v.apk'), v);
      expect(versionFromAssetName('xprs-$v-android-arm64-v8a.apk'), v);
      expect(versionFromAssetName('xprs-$v-android-armeabi-v7a.apk'), v);
      expect(versionFromAssetName('xprs-$v-android-x86_64.apk'), v);
      expect(versionFromAssetName('xprs-$v-linux-x64.tar.gz'), v);
      expect(versionFromAssetName('xprs-$v-windows-x64-setup.exe'), v);
    });

    test('a versionless name is not mistaken for a version', () {
      // The trap this repo shipped: CI emitted xprs-android-arm64-v8a.apk and
      // the folder path read the version as "android-arm64-v8a", offering a
      // release that never existed.
      expect(versionFromAssetName('xprs-android-arm64-v8a.apk'),
          isNot('1.1.1'));
      expect(compareSemver('android-arm64-v8a', '1.1.1'), lessThan(0));
    });
  });

  group('feed parsing', () {
    test('absolute asset urls pass through, sha256 is carried', () {
      final r = ReleaseInfo.fromFeed({
        'version': '1.2.0-beta.1',
        'prerelease': true,
        'assets': [
          {
            'name': 'xprs-1.2.0-beta.1-android-arm64-v8a.apk',
            'url': 'https://example.invalid/dl/xprs-1.2.0-beta.1-android-arm64-v8a.apk',
            'size': 56830740,
            'sha256': 'ae7acaeeeda738af4404ec901c97acdde1612053f1d5b036ea3b5f972edaf163',
          },
        ],
      }, baseUrl: 'https://xprs.dev/updates');

      expect(r.version, '1.2.0-beta.1');
      expect(r.isPrerelease, isTrue);
      expect(r.assets.single.url,
          'https://example.invalid/dl/xprs-1.2.0-beta.1-android-arm64-v8a.apk');
      expect(r.assets.single.sha256.length, 64);
      expect(r.assets.single.size, 56830740);
    });

    test('a prerelease is still rejected for the stable channel by version',
        () {
      expect(compareSemver('1.2.0-beta.1', '1.2.0'), lessThan(0));
      expect(compareSemver('1.2.0-beta.2', '1.2.0-beta.1'), greaterThan(0));
      expect(compareSemver('1.2.0', '1.1.1'), greaterThan(0));
    });
  });
}
