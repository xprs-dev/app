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

import 'package:xprs/services/preferences_service.dart';
import 'package:xprs/services/xprs/xprs_catchup.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:xprs/services/xprs/xprs_monitor.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

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
  Future<bool> send(String wire,
          {required int part, String slot = 'status', Duration? ttl}) async =>
      true;
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
    // The ordinary floor is section 36.10.1's ten minutes whatever this knob
    // says (it may only slow polling down), so the clock steps below are a
    // period apart in the cadence that actually applies.
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

  // `only:` is a CALLSIGN (36.6). Sending a type in it matched a station named
  // MESSAGE, which answers 404 — and 404 counts as "window done".
  test('the ask names a type in kind:, never in only:', () async {
    _beacon(now, count: 3);
    await XprsCatchup.instance.tick(_self);
    expect(aired.single, contains('kind:message'));
    expect(aired.single, contains('cmd:history'));
    expect(aired.single, contains('d:$_station'));
    expect(aired.single, isNot(contains('only:')));
  });

  test('206 resumes with until: and does NOT advance the watermark', () async {
    final prefs = PreferencesService.instanceSync!;
    final before = prefs.xprsCatchupMarks[_station] ?? prefs.xprsCatchupWatermark;

    _beacon(now, count: 3);
    await XprsCatchup.instance.tick(_self);
    final ask = XprsPacket.parse(aired.single)!;

    // The station served the newest slice and says it held more.
    XprsCatchup.instance.noteReplay(_station, now - 600000);
    XprsCatchup.instance.onResult(XprsPacket.parse(
        't:result f:$_station d:$_self ts:x r:${xprsIdentifier(ask)} code:206')!);

    expect(prefs.xprsCatchupMarks[_station] ?? prefs.xprsCatchupWatermark,
        before,
        reason: 'a partial page does not finish the window');

    // The next sweep continues from where the page stopped, even though the
    // beacon still says the same count.
    now += const Duration(minutes: 5).inMilliseconds;
    _beacon(now, count: 3);
    await XprsCatchup.instance.tick(_self);
    expect(aired, hasLength(2), reason: 'an unfinished page is itself news');
    expect(aired.last, contains('until:'));
  });

  // Over BLE a station publishes no count:/mail: -- those ride the
  // serve:archive announcement, which the firmware sends on ESP-NOW and the LAN
  // only. Suppressing on an unchanged "-1/-1" made the first ask the last one
  // forever, while the station filled up unread.
  test('a station that advertises no archive size is re-asked on a period',
      () async {
    final p = XprsPacket.parse(
        't:observation f:$_station link:ble peers:4'); // no count:, no mail:
    void blindBeacon(int at) => XprsMonitor.instance
        .offer(p!, bearer: 'ble', selfCallsign: _self, rssi: -50, nowMs: at);

    blindBeacon(now);
    await XprsCatchup.instance.tick(_self);
    expect(aired, hasLength(1), reason: 'a new station is always news');

    // Well inside the blind period: silence, or this becomes a flood.
    now += const Duration(minutes: 4).inMilliseconds;
    blindBeacon(now);
    await XprsCatchup.instance.tick(_self);
    expect(aired, hasLength(1),
        reason: 'no signal is not a licence to ask constantly');

    // Past it: ask again, because time is the only signal this bearer gives.
    now += const Duration(minutes: 7).inMilliseconds;
    blindBeacon(now);
    await XprsCatchup.instance.tick(_self);
    expect(aired, hasLength(2), reason: 'a blind station must not go unasked');
  });

  // An archiver holding nothing answers 404, which IS an answer. With one
  // shared mark it advanced the window for every other station too, so the
  // peer next door holding a week of traffic was asked only for what came
  // after the empty one replied.
  // The backstop must not be switchable-off by state going stale.
  //
  // A phone that spends twenty minutes on WiFi learns a station's count: over
  // the LAN, then goes back to BLE where nothing can ever refresh it. If the
  // periodic ask is conditional on "this station never published a count", it
  // switches itself off at that moment and the comparison goes on succeeding
  // against a number frozen in the past. Stale knowledge is worse than none,
  // because it looks like knowledge.
  test('a station whose count went stale is still asked on the period',
      () async {
    _beacon(now, count: 7); // learned once, e.g. over another bearer
    await XprsCatchup.instance.tick(_self);
    expect(aired, hasLength(1));

    // The count never moves again -- nothing on this bearer can refresh it.
    now += const Duration(minutes: 4).inMilliseconds;
    _beacon(now, count: 7);
    await XprsCatchup.instance.tick(_self);
    expect(aired, hasLength(1), reason: 'inside the period, stay quiet');

    now += const Duration(minutes: 7).inMilliseconds;
    _beacon(now, count: 7);
    await XprsCatchup.instance.tick(_self);
    expect(aired, hasLength(2),
        reason: 'a frozen count must not silence the poller for good');
  });

  test('an empty station does not narrow the window on a full one', () async {
    const other = 'X3OTHER';
    final pOther = XprsPacket.parse(
        't:observation f:$other link:ble peers:1 serve:archive count:9');
    XprsMonitor.instance.offer(pOther!,
        bearer: 'ble', selfCallsign: _self, rssi: -50, nowMs: now);
    _beacon(now, count: 3);

    await XprsCatchup.instance.tick(_self);
    expect(aired, hasLength(2), reason: 'both stations are new');

    final askOther = XprsPacket.parse(
        aired.firstWhere((w) => w.contains('d:$other')))!;
    final sinceBefore = XprsPacket.parse(
        aired.firstWhere((w) => w.contains('d:$_station')))!['since'];

    // The other station holds nothing for us.
    XprsCatchup.instance.onResult(XprsPacket.parse(
        't:result f:$other d:$_self ts:x r:${xprsIdentifier(askOther)} '
        'code:404')!);

    // Our full station is asked again and must still start where it did.
    now += const Duration(minutes: 12).inMilliseconds;
    _beacon(now, count: 4);
    aired.clear();
    await XprsCatchup.instance.tick(_self);
    final reAsk = aired.firstWhere((w) => w.contains('d:$_station'));
    expect(XprsPacket.parse(reAsk)!['since'], sinceBefore,
        reason: "another station's 404 must not move this one's window");
  });

  test('200 finishes the window and advances that station\'s mark', () async {
    final prefs = PreferencesService.instanceSync!;
    final before = prefs.xprsCatchupMarks[_station] ?? prefs.xprsCatchupWatermark;

    _beacon(now, count: 3);
    await XprsCatchup.instance.tick(_self);
    final ask = XprsPacket.parse(aired.single)!;

    XprsCatchup.instance.onResult(XprsPacket.parse(
        't:result f:$_station d:$_self ts:x r:${xprsIdentifier(ask)} code:200')!);
    expect(prefs.xprsCatchupMarks[_station], greaterThan(before),
        reason: 'the mark belongs to the station that answered');
  });

  test('429 answers nothing: the window stays open', () async {
    final prefs = PreferencesService.instanceSync!;
    final before = prefs.xprsCatchupMarks[_station] ?? prefs.xprsCatchupWatermark;

    _beacon(now, count: 3);
    await XprsCatchup.instance.tick(_self);
    final ask = XprsPacket.parse(aired.single)!;

    XprsCatchup.instance.onResult(XprsPacket.parse(
        't:result f:$_station d:$_self ts:x r:${xprsIdentifier(ask)} code:429')!);
    expect(prefs.xprsCatchupMarks[_station] ?? prefs.xprsCatchupWatermark,
        before);
  });

  // ── A fresh install (36.9.4 + 36.10.1 rule 4) ───────────────────────────
  //
  // The report that started this: XPRS installed on a new phone showed an
  // empty Global chat. Not a failed fetch — an absent one. The operator's
  // super list is empty until somebody types in it, a phone with nothing in
  // earshot has no heard stations either, and the sweep returns early when
  // both are empty, so no ask was ever sent and nothing said why.

  /// A device with nothing configured and nothing fetched yet.
  void freshInstall() {
    final prefs = PreferencesService.instanceSync!;
    prefs.xprsSuperArchivers = const [];
    prefs.xprsSuperArchiversLearned = const [];
    prefs.xprsCatchupMarks = const {};
  }

  /// A beacon from [call] that claims the super-archiver role.
  void superBeacon(String call, int nowMs) {
    final p = XprsPacket.parse(
        't:observation f:$call link:ble peers:1 serve:archive,super count:9');
    XprsMonitor.instance
        .offer(p!, bearer: 'ble', selfCallsign: _self, rssi: -50, nowMs: nowMs);
  }

  test('a super heard on the air is remembered; an ordinary archiver is not',
      () async {
    final prefs = PreferencesService.instanceSync!;
    freshInstall();
    superBeacon('X1SUPER', now);
    expect(XprsCatchup.learnedSupers(prefs), contains('X1SUPER'));

    _beacon(now, count: 3); // serve:archive, no super
    expect(XprsCatchup.learnedSupers(prefs), isNot(contains(_station)),
        reason: 'only serve:…,super earns the word');
  });

  test('discovery never writes the operator\'s own list', () async {
    freshInstall();
    final prefs = PreferencesService.instanceSync!;
    prefs.xprsSuperArchivers = const ['X9MINE'];
    superBeacon('X1SUPER', now);
    expect(prefs.xprsSuperArchivers, const ['X9MINE'],
        reason: 'a callsign the radio heard must not edit what a person typed');
  });

  test('a fresh install with only a LEARNED super still asks it', () async {
    final prefs = PreferencesService.instanceSync!;
    freshInstall();
    expect(prefs.xprsSuperArchivers, isEmpty, reason: 'nothing configured');
    superBeacon('X1SUPER', now);
    await XprsCatchup.instance.tick(_self);
    expect(aired.where((w) => w.contains('d:X1SUPER')), hasLength(1),
        reason: 'the whole bug: this used to ask nobody at all');
  });

  // Rule 4 bounds the POLL to seven days and says in the same breath that
  // anything older is fetched deliberately. This is that deliberate fetch.
  test('the first-run backfill reaches a month back, not a week', () async {
    freshInstall();
    superBeacon('X1SUPER', now);
    await XprsCatchup.instance.tick(_self);
    final ask = aired.firstWhere((w) => w.contains('d:X1SUPER'));
    final since = RegExp(r'since:(\S+)').firstMatch(ask)!.group(1)!;
    final asked = DateTime.parse(since.replaceFirst('_', ' ') + 'Z');
    final backMs = now - asked.millisecondsSinceEpoch;
    expect(backMs,
        greaterThan(const Duration(days: 20).inMilliseconds),
        reason: 'an empty archive asks for the month, not the week');
    expect(backMs,
        lessThanOrEqualTo(const Duration(days: 31).inMilliseconds));
  });

  test('the backfill is reported so a quiet first run is readable', () async {
    freshInstall();
    superBeacon('X1SUPER', now);
    await XprsCatchup.instance.tick(_self);
    final st = XprsCatchup.instance.statusJson()['backfill']
        as Map<String, dynamic>;
    expect(st['station'], 'X1SUPER');
    expect(st['target'], XprsCatchup.backfillMessages);
    expect(st['days'], XprsCatchup.backfillWindow.inDays);
  });
}
