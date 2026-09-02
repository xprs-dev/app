/*
 * Digipeat vs bridge, and the rules that keep them from being a flood.
 *
 * The phone had half of one of these. `XprsDigipeater.heard` took no bearer, so
 * the only implementation possible was one that aired on a single hardcoded
 * lane — a packet heard on the LAN was repeated onto Bluetooth and never back
 * onto the LAN, and a packet heard on Bluetooth never reached the LAN. An
 * unlabelled gateway in one direction and a wall in the other.
 *
 * The firmware has had it right in `bridge_out` all along: repeat on the medium
 * it came from, offer to the others, with the source as the discriminator.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_bridge.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

const _ts = '2026-09-02_16:00:00';
XprsPacket _p(String w) => XprsPacket.parse(w)!;

/// Stand-in for MeshService._relayable: appends `via:` and allows the relay.
String? relayOk(String wire) {
  final p = XprsPacket.parse(wire);
  if (p == null) return null;
  return p.with_('via', 'X1SELF').encode();
}

void main() {
  late List<({String wire, String lane})> aired;

  setUp(() {
    XprsBridge.debugReset();
    aired = [];
    XprsBridge.instance.relayable = relayOk;
    XprsBridge.instance.air = (w, lane) async {
      aired.add((wire: w, lane: lane));
      return true;
    };
  });
  tearDown(XprsBridge.debugReset);

  Future<void> heard(String wire, String bearer) async {
    XprsBridge.instance.heard(_p(wire), wire, bearer);
    await Future<void>.delayed(Duration.zero); // the carry is async
  }

  test('heard on BLE goes to the LAN, and not back onto BLE', () async {
    await heard('t:message f:X1QZ3N d:X3ARK ts:$_ts m:hello', 'ble5');
    expect(aired.map((a) => a.lane), ['lan'],
        reason: 'repeating onto BLE is the digipeater, not the bridge');
    expect(aired.single.wire, contains('via:X1SELF'),
        reason: 'a bridge is a relay and says so');
  });

  test('heard on the LAN goes to BLE — the direction that did not exist',
      () async {
    await heard('t:message f:X1QZ3N d:X3ARK ts:$_ts m:hello', 'lan');
    expect(aired.map((a) => a.lane), ['ble']);
  });

  test('ble and ble5 are one lane, not two', () async {
    await heard('t:message f:X1QZ3N d:X3ARK ts:$_ts m:hello', 'ble');
    expect(aired.map((a) => a.lane), ['lan']);
  });

  test('a local packet crosses short-range lanes and stops there', () async {
    // §13.11.1: `local` names the bearers in range, not a distance. BLE and the
    // LAN are both in range; an archiver is not.
    await heard('t:message f:X1QZ3N ts:$_ts scope:local m:in the room', 'ble5');
    expect(aired.map((a) => a.lane), ['lan']);
    expect(XprsBridge.skippedLocal, 1);
    expect(XprsBridge.toArchivers, 0);
  });

  test('a packet the relay rules refuse is not bridged either', () async {
    // A bridge is a relay: the §13.1 budget and §13.2 loop check decide both.
    XprsBridge.instance.relayable = (_) => null;
    await heard('t:message f:X1QZ3N d:X3ARK ts:$_ts m:hello', 'ble5');
    expect(aired, isEmpty);
    expect(XprsBridge.refusedByRule, 1);
  });

  test('the same packet heard twice is bridged once', () async {
    const w = 't:message f:X1QZ3N d:X3ARK ts:$_ts m:hello';
    await heard(w, 'ble5');
    await heard(w, 'ble5');
    expect(aired.length, 1);
  });

  test('the bridge can be switched off without touching the bearer', () async {
    XprsBridge.instance.policy =
        const XprsBridgePolicy(bridge: false, archivers: false);
    await heard('t:message f:X1QZ3N d:X3ARK ts:$_ts m:hello', 'ble5');
    expect(aired, isEmpty);
  });

  test('an unknown lane bridges to both known ones', () async {
    // A bearer this build does not know is not a reason to drop the packet;
    // it is a reason not to claim we repeated onto it.
    await heard('t:message f:X1QZ3N d:X3ARK ts:$_ts m:hello', 'espnow');
    expect(aired.map((a) => a.lane).toSet(), {'ble', 'lan'});
  });

  test('a repeat inside the window is suppressed, after it is not', () async {
    // The bench found this the hard way: the dedup had no window at all, so a
    // station repeating an identical beacon was bridged exactly once and the
    // LAN side never heard it again. Digipeat kept airing while the bridge sat
    // frozen at bridged:1 — and nothing counted the suppression, so the two
    // were indistinguishable from outside.
    var clock = 1000000;
    XprsBridge.instance.now = () => clock;
    const w = 't:message f:X1QZ3N d:X3ARK ts:$_ts m:hello';

    await heard(w, 'ble5');
    expect(aired.length, 1);

    clock += XprsBridge.seenMs ~/ 2; // still inside the window
    await heard(w, 'ble5');
    expect(aired.length, 1, reason: 'a repeat in the window is not re-carried');
    expect(XprsBridge.alreadyCarried, 1, reason: 'and it is counted, not silent');

    clock += XprsBridge.seenMs + 1; // past it
    await heard(w, 'ble5');
    expect(aired.length, 2,
        reason: 'a beacon repeating for an hour reaches the LAN more than once');
  });
}

