// The temperature around this device, as the stations in reach report it
// (XPRS.md 15.3). The rules are the core's, so they are pinned here rather than
// in a widget test: indoor and outdoor are separate keys, the unit is part of
// the value, a reading is dated by when it was measured, the station shown does
// not flap with a neighbour's, and the internet lane never feeds it.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/xprs/xprs_climate.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_monitor.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

const _self = 'X1SELF';

XprsPacket _p(String wire) => XprsPacket.parse(wire)!;

String _ts(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  final u = t.toUtc();
  return '${u.year}-${two(u.month)}-${two(u.day)}_'
      '${two(u.hour)}:${two(u.minute)}:${two(u.second)}';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('xprsTemperatureC', () {
    test('Celsius, with the precision it was sent at', () {
      expect(xprsTemperatureC('23C'), (23.0, 0));
      expect(xprsTemperatureC('14.2C'), (14.2, 1));
      expect(xprsTemperatureC('-3.5C'), (-3.5, 1));
      expect(xprsTemperatureC('14.0C'), (14.0, 1),
          reason: 'trailing zeros state the precision (4.4)');
    });

    test('Fahrenheit is converted to the canonical unit (15.9)', () {
      final (c, d) = xprsTemperatureC('57.6F')!;
      expect(c, closeTo(14.222, 0.001));
      expect(d, 1);
      expect(xprsTemperatureC('32F'), (0.0, 0));
    });

    test('a value without its unit, or in a foreign one, is skipped', () {
      for (final bad in [
        '23', '48km/h', '23c', '23 C', '14,2C', '.4C', '4.C', '+3C', '23K',
        '', 'hot',
      ]) {
        expect(xprsTemperatureC(bad), isNull, reason: bad);
      }
      expect(xprsTemperatureC(null), isNull);
    });

    test('a reading no air can have is a broken sensor', () {
      expect(xprsTemperatureC('850C'), isNull);
      expect(xprsTemperatureC('-273C'), isNull);
    });
  });

  group('ClimateReading.label', () {
    ClimateReading r(double c, int d) => ClimateReading(
        celsius: c, decimals: d, station: 'X3WX01', at: DateTime.utc(2026));
    test('keeps the digits that were sent', () {
      expect(r(23, 0).label, '23°C');
      expect(r(14.2, 1).label, '14.2°C');
      expect(r(14.222, 1).label, '14.2°C');
      expect(r(-3.5, 1).label, '-3.5°C');
    });
    test('never shows minus zero', () {
      expect(r(-0.4, 0).label, '0°C');
      expect(r(-0.04, 1).label, '0.0°C');
    });
  });

  group('xprsMeasuredAt', () {
    final heard = DateTime.utc(2026, 9, 11, 10, 0, 0);
    test('ts: when there is one', () {
      expect(
          xprsMeasuredAt(_p('t:observation f:X3A intemp:23C '
              'ts:2026-09-11_09:58:00'), heard),
          DateTime.utc(2026, 9, 11, 9, 58));
    });
    test('a clock that is ahead is read as now', () {
      expect(
          xprsMeasuredAt(_p('t:observation f:X3A intemp:23C '
              'ts:2026-09-11_11:00:00'), heard),
          heard);
    });
    test('age: for a sensor with no clock (15.7)', () {
      expect(xprsMeasuredAt(_p('t:observation f:X3A intemp:23C age:60'), heard),
          heard.subtract(const Duration(seconds: 60)));
    });
    test('neither: when it was heard', () {
      expect(xprsMeasuredAt(_p('t:observation f:X3A intemp:23C'), heard),
          heard);
    });
  });

  group('XprsClimate', () {
    late DateTime now;
    late XprsClimate w;

    setUp(() {
      now = DateTime.utc(2026, 9, 11, 10, 0, 0);
      w = XprsClimate(clock: () => now);
    });
    tearDown(() => w.reset());

    void obs(String from, String fields, {DateTime? at}) => w.heard(
        _p('t:observation f:$from $fields ts:${_ts(at ?? now)}'),
        from: from);

    test('indoor and outdoor are separate keys (15.3)', () {
      obs('X3WX01', 'temp:14.2C hum:78% intemp:21.5C inhum:54%');
      expect(w.current.value.outside?.label, '14.2°C');
      expect(w.current.value.inside?.label, '21.5°C');
    });

    test('an indoor-only station shows no outdoor value, and the reverse', () {
      obs('X3MEAV', 'intemp:23C inhum:53%');
      expect(w.current.value.inside?.label, '23°C');
      expect(w.current.value.outside, isNull);
      w.reset();
      obs('X3OUT', 'temp:9C');
      expect(w.current.value.inside, isNull);
      expect(w.current.value.outside?.label, '9°C');
    });

    test('observations with no reading change nothing', () {
      obs('X1PEER', 'hears:X1A,X1B link:ble');
      expect(w.current.value.isEmpty, isTrue);
      expect(w.accepted + w.malformed + w.stale, 0);
    });

    test('a malformed value is counted and leaves the shown one alone', () {
      obs('X3WX01', 'intemp:21C');
      obs('X3WX01', 'intemp:21', at: now.add(const Duration(minutes: 1)));
      expect(w.current.value.inside?.label, '21°C');
      expect(w.malformed, 1);
    });

    test('a reading measured too long ago is not shown', () {
      obs('X3WX01', 'intemp:21C',
          at: now.subtract(XprsClimate.fresh + const Duration(minutes: 1)));
      expect(w.current.value.isEmpty, isTrue);
      expect(w.stale, 1);
    });

    test('the station shown keeps its place while it is fresh', () {
      obs('X3AAAA', 'intemp:21C');
      now = now.add(const Duration(minutes: 1));
      obs('X3BBBB', 'intemp:25C');
      expect(w.current.value.inside?.station, 'X3AAAA',
          reason: 'two sensors in reach must not take turns on the screen');
      now = now.add(const Duration(minutes: 1));
      obs('X3AAAA', 'intemp:22C');
      expect(w.current.value.inside?.label, '22°C',
          reason: 'its own newer reading replaces it');
    });

    test('an older copy of the same station does not win (a relayed repeat)',
        () {
      obs('X3AAAA', 'intemp:22C');
      obs('X3AAAA', 'intemp:21C',
          at: now.subtract(const Duration(minutes: 2)));
      expect(w.current.value.inside?.label, '22°C');
    });

    test('another station takes over once the shown one goes quiet', () {
      obs('X3AAAA', 'intemp:21C');
      now = now.add(XprsClimate.fresh + const Duration(minutes: 1));
      obs('X3BBBB', 'intemp:25C');
      expect(w.current.value.inside?.station, 'X3BBBB');
    });

    test('sweep drops what went stale, side by side', () {
      obs('X3AAAA', 'intemp:21C');
      now = now.add(const Duration(minutes: 10));
      obs('X3OUT', 'temp:9C');
      now = now.add(const Duration(minutes: 6));
      w.sweep();
      expect(w.current.value.inside, isNull,
          reason: 'measured 16 minutes ago');
      expect(w.current.value.outside?.label, '9°C',
          reason: 'measured 6 minutes ago');
    });
  });

  group('the funnel', () {
    setUp(() {
      XprsMonitor.instance.debugReset();
      XprsClimate.instance.reset();
    });
    tearDown(() => XprsClimate.instance.reset());

    String wire(String fields) =>
        't:observation f:X3MEAV $fields ts:${_ts(DateTime.now())}';

    test('a station heard on a local lane feeds the reading', () {
      XprsIngest.heard(_p(wire('intemp:23C inhum:53%')),
          bearer: 'lan', selfCallsign: _self);
      expect(XprsClimate.instance.current.value.inside?.label, '23°C');
      expect(XprsClimate.instance.current.value.inside?.station, 'X3MEAV');
    });

    test('the internet lane does not: that air is somebody else\'s', () {
      XprsIngest.reticulum('aa11',
          Uint8List.fromList(utf8.encode(wire('intemp:23C inhum:53%'))));
      expect(XprsClimate.instance.current.value.isEmpty, isTrue);
    });

    test('our own echo is not a reading', () {
      XprsIngest.heard(
          _p('t:observation f:$_self intemp:23C ts:${_ts(DateTime.now())}'),
          bearer: 'ble',
          selfCallsign: _self);
      expect(XprsClimate.instance.current.value.isEmpty, isTrue);
    });
  });
}
