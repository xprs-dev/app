/*
 * Fetching a station's archived messages without knowing where they are
 * (XPRS.md 12.6, 12.9): the order archivers are asked in, the one-hop
 * `m:try` redirect, the 206 continuation, and what the funnel keeps.
 *
 * Every seam injected: no radio, no store, no clock.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_fetch.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

void main() {
  final f = XprsFetch.instance;
  const t0 = 1700000000000;
  late int now;
  late List<String> sent;
  late Set<String> earshot;
  late Set<String> busy;

  setUp(() {
    f.debugReset();
    now = t0;
    sent = [];
    earshot = {};
    busy = {};
    f
      ..autoTick = false
      ..nowMs = (() => now)
      ..send = ((w) async => sent.add(w))
      ..archivers = (() => ['X3ARC1', 'X3ARC2'])
      ..selfCallsign = (() => 'X1SELF')
      ..inEarshot = ((c) => earshot.contains(c))
      ..newestHeldMs = ((_) => null)
      ..archiverBusy = ((a) => busy.contains(a));
  });

  XprsPacket lastAsk() => XprsPacket.parse(sent.last)!;

  /// The archiver answers the last ask with [code] (and [m]).
  void answer(int code, {String? m, String? from}) {
    final ask = lastAsk();
    final r = xprsIdentifier(ask);
    final w = StringBuffer('t:result f:${from ?? ask['d']} d:X1SELF '
        'ts:2026-10-25_10:00:01 r:$r code:$code');
    if (m != null) w.write(' m:$m');
    f.onResult(XprsPacket.parse(w.toString())!);
  }

  /// A replayed row from X1BOA3 lands at the door.
  void row(String ts) {
    final p = XprsPacket.parse('t:message f:X1BOA3 ts:$ts m:old news')!;
    expect(f.askedFor(p), isTrue, reason: 'a row we asked for is kept');
    f.noteHeard(p);
  }

  test('the ask is 12.6\'s question, to the first chosen archiver', () async {
    expect(f.requestStation('X1BOA3'), isTrue);
    final ask = lastAsk();
    expect(ask.type, 'command');
    expect(ask['d'], 'X3ARC1');
    expect(ask['cmd'], 'history');
    expect(ask['only'], 'X1BOA3');
    expect(ask['kind'], 'message');
    expect(ask.has('since'), isTrue);
    expect(ask.has('scope'), isFalse, reason: 'directed, never scope:local');
  });

  test('a station in earshot is not fetched: the air carries it', () {
    earshot = {'X1BOA3'};
    expect(f.requestStation('X1BOA3'), isFalse);
    expect(sent, isEmpty);
  });

  test('one fetch per station per ten minutes', () async {
    expect(f.requestStation('X1BOA3'), isTrue);
    row('2026-10-20_10:00:00');
    answer(200);
    expect(f.json['open'], isEmpty, reason: 'answered: closed');
    expect(f.requestStation('X1BOA3'), isFalse, reason: 'just asked');
    now += XprsFetch.everyPerStation.inMilliseconds;
    expect(f.requestStation('X1BOA3'), isTrue);
  });

  test('nothing at the first archiver: the next one is asked', () async {
    f.requestStation('X1BOA3');
    answer(404);
    await Future<void>.delayed(Duration.zero);
    expect(sent, hasLength(2));
    expect(lastAsk()['d'], 'X3ARC2');
  });

  test('a 404 naming who knows is followed, one hop', () async {
    f.requestStation('X1BOA3');
    answer(404, m: 'try X3FAR1,X3FAR2');
    await Future<void>.delayed(Duration.zero);
    expect(lastAsk()['d'], 'X3ARC2', reason: 'the chosen ones first');
    answer(404);
    await Future<void>.delayed(Duration.zero);
    expect(lastAsk()['d'], 'X3FAR1', reason: 'then the redirect');
    // A hop from a hop is not followed.
    answer(404, m: 'try X3DEEP');
    await Future<void>.delayed(Duration.zero);
    expect(lastAsk()['d'], 'X3FAR2');
    answer(404);
    await Future<void>.delayed(Duration.zero);
    expect(sent.map((w) => XprsPacket.parse(w)!['d']).toList(),
        ['X3ARC1', 'X3ARC2', 'X3FAR1', 'X3FAR2'],
        reason: 'X3DEEP was named by a redirect and is never asked');
    expect(f.json['open'], isEmpty);
    expect(f.redirects, 2);
  });

  test('rows are counted, and 206 continues before the oldest, a few pages',
      () async {
    f.requestStation('X1BOA3');
    row('2026-10-24_10:00:00');
    row('2026-10-23_10:00:00');
    answer(206);
    await Future<void>.delayed(Duration.zero);
    expect(sent, hasLength(2));
    final cont = lastAsk();
    expect(cont['d'], 'X3ARC1', reason: 'the same archiver continues');
    expect(cont['until'], '2026-10-23_10:00:01');
    row('2026-10-22_10:00:00');
    answer(206);
    await Future<void>.delayed(Duration.zero);
    expect(lastAsk()['until'], '2026-10-22_10:00:01');
    row('2026-10-21_10:00:00');
    answer(206);
    await Future<void>.delayed(Duration.zero);
    expect(sent, hasLength(XprsFetch.maxPages), reason: 'a few pages, no more');
    expect(f.json['open'], isEmpty);
    expect(f.rows, 4);
    expect(f.found, 1);
  });

  test('a 206 that makes no progress is not chased', () async {
    f.requestStation('X1BOA3');
    row('2026-10-24_10:00:00');
    answer(206);
    await Future<void>.delayed(Duration.zero);
    expect(sent, hasLength(2));
    row('2026-10-24_10:00:00'); // the same boundary row again
    answer(206);
    await Future<void>.delayed(Duration.zero);
    expect(sent, hasLength(2), reason: 'the cursor did not move: stop');
    expect(f.json['open'], isEmpty);
  });

  test('the archiver that answered last time is asked first next time',
      () async {
    f.requestStation('X1BOA3');
    answer(404);
    await Future<void>.delayed(Duration.zero);
    row('2026-10-24_10:00:00');
    answer(200); // X3ARC2 had it
    now += XprsFetch.everyPerStation.inMilliseconds;
    f.requestStation('X1BOA3');
    expect(lastAsk()['d'], 'X3ARC2');
  });

  test('429 is the archiver\'s authority: move on, do not re-ask it', () async {
    f.requestStation('X1BOA3');
    answer(429);
    await Future<void>.delayed(Duration.zero);
    expect(lastAsk()['d'], 'X3ARC2');
    expect(f.refused, 1);
  });

  test('an archiver the poller is talking to waits for the next tick',
      () async {
    busy = {'X3ARC1'};
    f.requestStation('X1BOA3');
    expect(sent, isEmpty);
    busy = {};
    await f.tick();
    expect(lastAsk()['d'], 'X3ARC1');
  });

  test('an unanswered ask is given up after its grace', () async {
    f.requestStation('X1BOA3');
    now += XprsFetch.askGrace.inMilliseconds + 1;
    await f.tick();
    expect(lastAsk()['d'], 'X3ARC2');
    // And a late row for the stale ask is no longer "asked for".
    final p = XprsPacket.parse('t:message f:X1BOA3 ts:2026-10-24_10:00:00 m:x')!;
    expect(f.askedFor(p), isTrue, reason: 'the new ask is out');
  });

  test('only talk about the station counts: a beacon or a stranger does not',
      () {
    f.requestStation('X1BOA3');
    expect(f.askedFor(XprsPacket.parse(
            't:observation f:X1BOA3 link:ble peers:1 ts:2026-10-24_10:00:00')!),
        isFalse);
    expect(f.askedFor(XprsPacket.parse(
            't:message f:X1OTHR d:X1SELF ts:2026-10-24_10:00:00 m:hi')!),
        isFalse);
    expect(f.askedFor(XprsPacket.parse(
            't:message f:X1SELF d:X1BOA3 ts:2026-10-24_10:00:00 m:mine')!),
        isTrue, reason: 'our side of the conversation is about them too');
  });

  test('nobody to ask: nothing opened', () {
    f.archivers = (() => const []);
    expect(f.requestStation('X1BOA3'), isFalse);
  });
}
