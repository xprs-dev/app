// The catch-up poller against section 36.10.1.
//
// The behaviours that had to be wrong for a station's held mail to never
// arrive, each of which cost a real replay:
//   * asking at all when the station's beacon says nothing changed — a replay
//     is metered (six an hour known, two a stranger, section 31.2), so an ask
//     that can only be answered "nothing" is the one thing this must not spend;
//   * asking without `only:`, so the twelve-record page came back full of the
//     `t:observation` beacons the archive also keeps and the messages were
//     below the fold;
//   * treating `code:206` as "window done" and advancing the watermark past
//     everything the station could not fit, permanently.
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:aurora/services/preferences_service.dart';
import 'package:aurora/services/xprs/xprs_catchup.dart';
import 'package:aurora/services/xprs/xprs_publisher.dart';
import 'package:aurora/services/xprs/xprs_monitor.dart';
import 'package:aurora/services/xprs/xprs_id.dart';
import 'package:aurora/services/xprs/xprs_packet.dart';

/// A short-range bearer that is up. Without one the poller correctly refuses
/// to ask anything at all, and every test below would pass for the wrong
/// reason.
class _UpBearer implements XprsBearer {
  @override
  String get name => 'fake';
  @override
  String get archiveBearer => 'ble';
  @override
  bool get shortRange => true;
  @override
  Future<bool> get active async => true;
  @override
  Future<bool> send(String wire, {required int part, String slot = 'status'}) async => true;
}

const _self = 'X1SELF';
const _station = 'X3WWAJ';

/// A beacon from [_station] claiming an archive of [count] records.
void _beacon(int nowMs, {required int count, int? mail}) {
  final m = mail == null ? '' : ' mail:$mail';
  final p = XprsPacket.parse(
      't:observation f:$_station link:ble peers:1 serve:archive count:$count$m');
  XprsMonitor.instance
      .offer(p!, bearer: 'ble', selfCallsign: _self, rssi: -50, nowMs: nowMs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> aired;
  var now = DateTime.utc(2026, 8, 21, 12).millisecondsSinceEpoch;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PreferencesService.instance();
    final prefs = PreferencesService.instanceSync!;
    prefs.xprsCatchupMinutes = 1;
    // Non-zero, or the first tick just plants the mark and returns.
    prefs.xprsCatchupWatermark = now ~/ 1000 - 3600;

    aired = [];
    final c = XprsCatchup.instance;
    c.nowMs = () => now;
    c.sendOverride = (wire) async {
      aired.add(wire);
      return {'ble5': 'sent'};
    };
    XprsPublisher.instance.bearers = [_UpBearer()];
    c.debugReset();
    XprsMonitor.instance.debugReset();
  });

  test('a station whose beacon has not changed is not asked twice', () async {
    _beacon(now, count: 10);
    await XprsCatchup.instance.tick(_self);
    expect(aired, hasLength(1), reason: 'a station never asked before is news');

    // Same numbers, a period later: there is nothing to fetch and a replay
    // must not be spent finding that out.
    now += const Duration(minutes: 5).inMilliseconds;
    _beacon(now, count: 10);
    await XprsCatchup.instance.tick(_self);
    expect(aired, hasLength(1), reason: 'unchanged count: must ask nothing');

    // The station archived something. NOW it is worth a replay.
    now += const Duration(minutes: 5).inMilliseconds;
    _beacon(now, count: 11);
    await XprsCatchup.instance.tick(_self);
    expect(aired, hasLength(2), reason: 'count: moved — ask');
  });

  test('the ask is for messages, not for the whole archive', () async {
    _beacon(now, count: 3);
    await XprsCatchup.instance.tick(_self);
    expect(aired.single, contains('only:message'));
    expect(aired.single, contains('cmd:history'));
    expect(aired.single, contains('d:$_station'));
  });

  test('206 resumes with until: and does NOT advance the watermark', () async {
    final prefs = PreferencesService.instanceSync!;
    final before = prefs.xprsCatchupWatermark;

    _beacon(now, count: 3);
    await XprsCatchup.instance.tick(_self);
    final ask = XprsPacket.parse(aired.single)!;

    // The station served the newest slice and says it held more.
    XprsCatchup.instance.noteReplay(_station, now - 600000);
    XprsCatchup.instance.onResult(XprsPacket.parse(
        't:result f:$_station d:$_self ts:x r:${xprsIdentifier(ask)} code:206')!);

    expect(prefs.xprsCatchupWatermark, before,
        reason: 'a partial page does not finish the window');

    // The next sweep continues from where the page stopped, even though the
    // beacon still says the same count.
    now += const Duration(minutes: 2).inMilliseconds;
    _beacon(now, count: 3);
    await XprsCatchup.instance.tick(_self);
    expect(aired, hasLength(2), reason: 'an unfinished page is itself news');
    expect(aired.last, contains('until:'));
  });

  test('200 finishes the window and advances the watermark', () async {
    final prefs = PreferencesService.instanceSync!;
    final before = prefs.xprsCatchupWatermark;

    _beacon(now, count: 3);
    await XprsCatchup.instance.tick(_self);
    final ask = XprsPacket.parse(aired.single)!;

    XprsCatchup.instance.onResult(XprsPacket.parse(
        't:result f:$_station d:$_self ts:x r:${xprsIdentifier(ask)} code:200')!);
    expect(prefs.xprsCatchupWatermark, greaterThan(before));
  });

  test('429 answers nothing: the window stays open', () async {
    final prefs = PreferencesService.instanceSync!;
    final before = prefs.xprsCatchupWatermark;

    _beacon(now, count: 3);
    await XprsCatchup.instance.tick(_self);
    final ask = XprsPacket.parse(aired.single)!;

    XprsCatchup.instance.onResult(XprsPacket.parse(
        't:result f:$_station d:$_self ts:x r:${xprsIdentifier(ask)} code:429')!);
    expect(prefs.xprsCatchupWatermark, before);
  });
}
