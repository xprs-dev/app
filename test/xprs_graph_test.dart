// The local topology, walked (docs/XPRS.md 10.6.3, 10.6.5, 36.0).
//
// The one thing worth testing hardest is the DIRECTION. `hears:` is about
// reception, so an edge "B hears A" is what lets A transmit to B, and walking
// the edges the way they are written yields paths that look right and cannot
// carry anything. 10.6.5 says the two directions genuinely differ: "a handheld
// hears a hilltop repeater that cannot hear it back".
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_gossip.dart';
import 'package:xprs/services/xprs/xprs_graph.dart';

const int now = 1700000000000;

/// `observer` hears `heard` — the way an observation states it.
GossipEdge hears(String observer, String heard, String bearer,
        {int ageS = 10}) =>
    GossipEdge(observer, heard, bearer, now - ageS * 1000);

void main() {
  test('two hops across two different bearers', () {
    // The bench: TANK2 is Bluetooth-only, the desktop is LAN-only, the T-Deck
    // hears both. For TANK2 to reach the desktop, the T-Deck must hear TANK2
    // and the desktop must hear the T-Deck.
    final g = XprsGraph([
      hears('X3GSLC', 'X1VCVM', 'ble'),
      hears('X16JK8', 'X3GSLC', 'lan'),
    ], nowMs: now);

    final p = g.pathTo('X16JK8', from: 'X1VCVM')!;
    expect(p.hops.map((h) => h.to).toList(), ['X3GSLC', 'X16JK8']);
    expect(p.hops.map((h) => h.bearer).toList(), ['ble', 'lan']);
    expect(p.relays, 1); // one relay, which is what via: would hold
  });

  test('hearing is asymmetric: the reverse path is not implied', () {
    // Only "X3GSLC hears X1VCVM" is known. That lets X1VCVM transmit to
    // X3GSLC and says nothing about the other direction (10.6.5).
    final g = XprsGraph([hears('X3GSLC', 'X1VCVM', 'ble')], nowMs: now);
    expect(g.pathTo('X3GSLC', from: 'X1VCVM'), isNotNull);
    expect(g.pathTo('X1VCVM', from: 'X3GSLC'), isNull,
        reason: 'a one-way hearing must not yield a path back');
  });

  test('a destination nobody hears is unreachable', () {
    final g = XprsGraph([hears('X3GSLC', 'X1VCVM', 'ble')], nowMs: now);
    expect(g.pathTo('X9ZZZZ', from: 'X1VCVM'), isNull);
  });

  test('stale evidence is dropped, not merely ranked lower', () {
    final g = XprsGraph([
      hears('X3GSLC', 'X1VCVM', 'ble', ageS: 30),
      hears('X16JK8', 'X3GSLC', 'lan', ageS: 7200), // two hours old
    ], nowMs: now, maxAgeMs: 3600000);
    expect(g.pathTo('X16JK8', from: 'X1VCVM'), isNull);
  });

  test('reliability outranks hop count (36.0)', () {
    // A two-hop path resting on a fifty-minute-old claim, against a three-hop
    // path every link of which was confirmed seconds ago. 36.0: "a fast path
    // that has not carried anything lately is a guess, and a slower one that
    // answered a minute ago is knowledge."
    final g = XprsGraph([
      hears('X0SLOW', 'X1VCVM', 'lora', ageS: 3000),
      hears('X16JK8', 'X0SLOW', 'lora', ageS: 3000),
      hears('X3GSLC', 'X1VCVM', 'ble', ageS: 5),
      hears('X3MIDL', 'X3GSLC', 'lan', ageS: 5),
      hears('X16JK8', 'X3MIDL', 'lan', ageS: 5),
    ], nowMs: now);

    final p = g.pathTo('X16JK8', from: 'X1VCVM')!;
    expect(p.hops.map((h) => h.to).toList(), ['X3GSLC', 'X3MIDL', 'X16JK8']);
    expect(p.worstAgeMs, lessThan(60000));
  });

  test('a path longer than 13.1 would carry is not offered', () {
    // Four relays. The network refuses at three for ordinary traffic, so
    // returning it would be describing a delivery that cannot happen.
    final g = XprsGraph([
      hears('B', 'A', 'lora'),
      hears('C', 'B', 'lora'),
      hears('D', 'C', 'lora'),
      hears('E', 'D', 'lora'),
      hears('F', 'E', 'lora'),
    ], nowMs: now, maxRelays: 3);
    expect(g.pathTo('F', from: 'A'), isNull);
    expect(g.pathTo('E', from: 'A'), isNotNull);
  });

  test('worstAgeMs reports the stalest link, not the freshest', () {
    final g = XprsGraph([
      hears('X3GSLC', 'X1VCVM', 'ble', ageS: 5),
      hears('X16JK8', 'X3GSLC', 'lan', ageS: 900),
    ], nowMs: now);
    final p = g.pathTo('X16JK8', from: 'X1VCVM')!;
    expect(p.worstAgeMs, 900 * 1000);
  });

  test('an edge we witnessed ourselves is marked direct', () {
    final g = XprsGraph([
      GossipEdge('X3GSLC', 'X1VCVM', 'ble', now - 5000, direct: true),
    ], nowMs: now);
    expect(g.pathTo('X3GSLC', from: 'X1VCVM')!.allDirect, isTrue);
  });
}
