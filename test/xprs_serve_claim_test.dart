// What this station says it does, and how a peer works out the rest.
//
// The app used to air `serve:archive,super`. `super` is not in XPRS.md 13's
// vocabulary, so it was a claim only this implementation could make and only
// this implementation could read -- and it was aired beside `files` whether or
// not the device hosted a single byte for anybody. Both halves are settled
// here: the claim says what is true, and "always on" is inferred from 12.9.4's
// qualities rather than announced as a rank.
import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/xprs/xprs_station_policy.dart';

void main() {
  group('what a station claims', () {
    test('a private phone claims nothing', () {
      expect(
          xprsServeClaim(public: false, spoolReady: true, files: false), isNull);
    });

    test('a public archiver claims the archive role, and only that', () {
      expect(xprsServeClaim(public: true, spoolReady: true, files: false),
          'archive');
    });

    test('files is claimed only by a device actually hosting them', () {
      // This rode along with `archive` unconditionally, on phones with
      // archive.quotaGb at 0 -- an offer nobody could collect on.
      expect(xprsServeClaim(public: true, spoolReady: true, files: true),
          'archive,files');
      expect(xprsServeClaim(public: false, spoolReady: true, files: true),
          'files',
          reason: 'hosting files is a separate consent from keeping packets');
    });

    test('a spool that has not opened yet promises nothing', () {
      expect(
          xprsServeClaim(public: true, spoolReady: false, files: false), isNull);
    });

    test('the word super is never aired, in any combination', () {
      for (final p in [true, false]) {
        for (final s in [true, false]) {
          for (final f in [true, false]) {
            final claim =
                xprsServeClaim(public: p, spoolReady: s, files: f) ?? '';
            expect(claim.contains('super'), false, reason: '$p/$s/$f');
          }
        }
      }
    });
  });

  group('what a peer infers (12.9.4)', () {
    bool looks({
      String callsign = 'X3ARK',
      List<String> services = const ['archive'],
      String bearer = 'rns',
      int count = 0,
      int uptimeSeconds = 0,
      Set<String> named = const {},
    }) =>
        xprsLooksAlwaysOn(
          callsign: callsign,
          services: services,
          bearer: bearer,
          count: count,
          uptimeSeconds: uptimeSeconds,
          named: named,
        );

    test('the operator naming one settles it', () {
      expect(looks(named: {'X3ARK'}, services: const [], bearer: 'lora'), true,
          reason: 'an archiver reached only over the internet is never heard '
              'on a radio, so it has no beacon to judge');
    });

    test('a station not offering the archive role is not one', () {
      expect(looks(services: const ['relay'], count: 999999), false);
    });

    test('deep counts', () {
      expect(looks(count: 10000), true);
      expect(looks(count: 9999), false);
    });

    test('long awake counts', () {
      expect(looks(uptimeSeconds: 7 * 24 * 3600), true);
      expect(looks(uptimeSeconds: 6 * 24 * 3600), false);
    });

    test('addressable or it does not count', () {
      // Depth on a station you have to stand next to is not a promise you can
      // collect on from somewhere else.
      expect(looks(bearer: 'lora', count: 999999), false);
      expect(looks(bearer: 'ble5', count: 999999), false);
      expect(looks(bearer: 'lan', count: 999999), true);
    });
  });

  group('uptime as a number (10.5)', () {
    test('the shorthand the spec asks for', () {
      expect(xprsUptimeSeconds('26h'), 26 * 3600);
      expect(xprsUptimeSeconds('9d'), 9 * 86400);
      expect(xprsUptimeSeconds('90m'), 5400);
      expect(xprsUptimeSeconds('45'), 45, reason: 'bare is seconds');
    });

    test('nothing stated is nothing claimed', () {
      expect(xprsUptimeSeconds(null), 0);
      expect(xprsUptimeSeconds(''), 0);
      expect(xprsUptimeSeconds('ages'), 0);
    });
  });
}
