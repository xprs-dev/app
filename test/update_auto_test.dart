// The decisions behind automatic updates: is it on by default, is a check
// due, is the download on disk already the one wanted, what the launcher
// shows. Pure Dart; the network, the DownloadManager and the installer belong
// with tool/update_net_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/update_models.dart';

void main() {
  group('defaultAutoUpdate', () {
    test('desktop is on', () {
      expect(
          defaultAutoUpdate(android: false, installer: null, storeDefine: false),
          isTrue);
    });

    test('an F-Droid client install is off, whatever the define', () {
      for (final c in fdroidClientPackages) {
        expect(
            defaultAutoUpdate(android: true, installer: c, storeDefine: true),
            isFalse,
            reason: c);
      }
    });

    test('a sideloaded install is on even with AUTO_UPDATE_CHECK=false', () {
      for (final who in [
        'com.google.android.packageinstaller',
        'com.android.packageinstaller',
        'com.android.chrome',
        'com.xprs.app',
      ]) {
        expect(
            defaultAutoUpdate(android: true, installer: who, storeDefine: false),
            isTrue,
            reason: who);
      }
    });

    test('no installer on record (adb) follows the define', () {
      expect(
          defaultAutoUpdate(android: true, installer: null, storeDefine: false),
          isFalse);
      expect(
          defaultAutoUpdate(android: true, installer: '', storeDefine: true),
          isTrue);
    });
  });

  group('updateCheckDue / updateNextCheckIn', () {
    const six = Duration(hours: 6);
    const min = Duration(minutes: 1);
    final now = DateTime.utc(2026, 11, 14, 12).millisecondsSinceEpoch;
    int ago(Duration d) => now - d.inMilliseconds;

    test('never checked is due', () {
      expect(updateCheckDue(lastCheckMs: null, nowMs: now, interval: six),
          isTrue);
      expect(updateCheckDue(lastCheckMs: 0, nowMs: now, interval: six), isTrue);
    });

    test('due exactly at the interval, not before', () {
      expect(
          updateCheckDue(
              lastCheckMs: ago(const Duration(hours: 5, minutes: 59)),
              nowMs: now,
              interval: six),
          isFalse);
      expect(updateCheckDue(lastCheckMs: ago(six), nowMs: now, interval: six),
          isTrue);
    });

    test('a clock that went backwards is due', () {
      expect(
          updateCheckDue(
              lastCheckMs: now + 3600 * 1000, nowMs: now, interval: six),
          isTrue);
    });

    test('next check: the remainder of the interval, never under the floor',
        () {
      expect(
          updateNextCheckIn(
              lastCheckMs: ago(const Duration(hours: 2)),
              nowMs: now,
              interval: six,
              minDelay: min),
          const Duration(hours: 4));
      expect(
          updateNextCheckIn(
              lastCheckMs: ago(const Duration(hours: 5, minutes: 59, seconds: 30)),
              nowMs: now,
              interval: six,
              minDelay: min),
          min);
      expect(
          updateNextCheckIn(
              lastCheckMs: null, nowMs: now, interval: six, minDelay: min),
          min);
    });
  });

  group('readyCovers / readyIsStale', () {
    test('the download on disk is reused for the same, newer version', () {
      expect(
          readyCovers(readyVersion: '1.3.0', wanted: '1.3.0', running: '1.2.9'),
          isTrue);
    });

    test('not for another version, nor once it is the one running', () {
      expect(
          readyCovers(readyVersion: '1.3.0', wanted: '1.3.1', running: '1.2.9'),
          isFalse);
      expect(
          readyCovers(readyVersion: '1.3.0', wanted: '1.3.0', running: '1.3.0'),
          isFalse);
      expect(readyCovers(readyVersion: null, wanted: '1.3.0', running: '1.2.9'),
          isFalse);
    });

    test('build metadata does not make it a different version', () {
      expect(
          readyCovers(
              readyVersion: '1.3.0+400500', wanted: '1.3.0', running: '1.2.9'),
          isTrue);
    });

    test('stale once installed or older than what runs', () {
      expect(readyIsStale(readyVersion: '1.3.0', running: '1.3.0'), isTrue);
      expect(readyIsStale(readyVersion: '1.2.0', running: '1.3.0'), isTrue);
      expect(readyIsStale(readyVersion: '1.3.0-beta.2', running: '1.3.0-beta.1'),
          isFalse);
    });
  });

  group('updateNoticeFor', () {
    test('ready beats downloading beats available', () {
      expect(
          updateNoticeFor(newerKnown: true, downloading: true, ready: true),
          UpdateNotice.ready);
      expect(
          updateNoticeFor(newerKnown: true, downloading: true, ready: false),
          UpdateNotice.downloading);
      expect(
          updateNoticeFor(newerKnown: true, downloading: false, ready: false),
          UpdateNotice.available);
      expect(
          updateNoticeFor(newerKnown: false, downloading: false, ready: false),
          UpdateNotice.none);
    });
  });
}
