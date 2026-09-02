// The digipeater (docs/XPRS.md 13.1, 13.2, 13.2.1).
//
// A relay "repeats a packet on the medium it heard it, within the hop budget,
// appending itself to `via:`". What keeps that from becoming a storm is four
// rules, and each one is a test here — because the failure mode of getting any
// of them wrong is a room full of radios shouting the same packet at once.
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_digipeat.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_vocab.dart';

const String self = 'X3SELF';
const String ts = '2026-08-27_20:00:00';

/// The real 13.1/13.2 decision, as MeshService wires it.
String? relayable(String wire) {
  final p = XprsPacket.parse(wire);
  if (p == null) return null;
  // Mirrors MeshService._relayable, including 13.2.2's gate.
  if (xprsRelay(p).isNotEmpty && !xprsRelayNextIs(p, self)) return null;
  if (xprsWouldLoop(p, self)) return null;
  if (!xprsMayRelay(p)) return null;
  final out = xprsAppendVia(p, self);
  return out.fits ? out.encode() : null;
}

void main() {
  late List<String> aired;
  late XprsDigipeater d;
  var clock = 1000000;
  var enabled = true;
  late List<String> lanes;

  setUp(() {
    aired = [];
    lanes = [];
    enabled = true;
    clock = 1000000;
    d = XprsDigipeater(
      // The bearer is part of the answer now: §13.1 repeats "on the medium it
      // heard it", and a repeater that takes no bearer can only ever honour
      // that by accident.
      air: (w, lane) async {
        aired.add(w);
        lanes.add(lane);
        return true;
      },
      relayable: relayable,
      enabled: (_) => enabled,
    );
    // Separate statements, not a cascade: `..random` after `() => clock`
    // parses as a cascade on `clock` itself, which is an int.
    d.now = () => clock;
    d.random = (_) => 0; // the minimum wait, unless a test says otherwise
  });

  tearDown(() => d.dispose());

  XprsPacket pkt(String wire) => XprsPacket.parse(wire)!;
  void hear(String wire, [String bearer = 'ble']) =>
      d.heard(pkt(wire), wire, bearer);
  Future<void> advance(int ms) async {
    clock += ms;
    await d.pump();
  }

  const msg = 't:message f:X1AAAA d:X1BBBB ts:$ts m:hello';

  test('waits before repeating, then repeats with via: (13.2.1, 13.1)', () async {
    hear(msg);
    expect(aired, isEmpty, reason: 'aired instantly — the wait is the point');

    await advance(XprsDigipeater.jitterMinMs - 1);
    expect(aired, isEmpty);

    await advance(2);
    expect(aired, hasLength(1));
    expect(aired.single, contains('via:$self'));
    expect(aired.single, contains('m:hello'), reason: 'payload altered');
  });

  test('hearing it RELAYED during the wait cancels ours (13.2.1)', () async {
    hear(msg);
    hear('t:message f:X1AAAA d:X1BBBB ts:$ts via:X9OTHER m:hello');
    await advance(2000);
    expect(aired, isEmpty);
    expect(d.cancelled, 1);
  });

  test('the origin repeating itself does NOT cancel ours', () async {
    // The opposite signal: nobody has carried it yet, which is exactly when a
    // digipeater should.
    hear(msg);
    hear(msg);
    await advance(2000);
    expect(aired, hasLength(1));
    expect(d.cancelled, 0);
  });

  test('an author echoing itself in via: does not cancel ours', () async {
    // The defect real phones shipped with: the author appends ITSELF to the
    // `via:` of its own packet. Cancelling on that copy means every digipeater
    // in the room stands down when the origin merely repeats itself — the
    // opposite of 13.2.1, which stands down only when somebody ELSE carried it.
    hear(msg);
    hear('t:message f:X1AAAA d:X1BBBB ts:$ts via:X1AAAA m:hello');
    await advance(2000);
    expect(aired, hasLength(1),
        reason: "the author's own via: cancelled our relay");
    expect(d.cancelled, 0);
  });

  test('the author among others still cancels', () async {
    hear(msg);
    hear('t:message f:X1AAAA d:X1BBBB ts:$ts via:X1AAAA,X9OTHER m:hello');
    await advance(2000);
    expect(aired, isEmpty);
    expect(d.cancelled, 1);
  });

  test('our own callsign in via: means hands off (13.2)', () async {
    hear('t:message f:X1AAAA d:X1BBBB ts:$ts via:$self m:hello');
    await advance(2000);
    expect(aired, isEmpty);
  });

  test('a spent hop budget is not relayed (13.1)', () async {
    // Three relays is the limit for ordinary traffic.
    hear('t:message f:X1AAAA d:X1BBBB ts:$ts via:X1,X2,X3 m:hello');
    await advance(2000);
    expect(aired, isEmpty);

    // sos gets nine, so the same path is still travelling.
    hear('t:sos f:X1AAAA ts:$ts via:X1,X2,X3 m:help');
    await advance(2000);
    expect(aired, hasLength(1));
  });

  test('we never repeat what we have already repeated', () async {
    hear(msg);
    await advance(2000);
    expect(aired, hasLength(1));

    hear(msg); // heard again, minutes later in a real room
    await advance(2000);
    expect(aired, hasLength(1), reason: 'repeated its own repeat');
  });

  test('the wait is inside 13.2.1s window and is random', () async {
    d.random = (max) => max - 1; // the top of the range
    hear(msg);
    await advance(XprsDigipeater.jitterMaxMs - 1);
    expect(aired, isEmpty, reason: 'aired before the window closed');
    await advance(2);
    expect(aired, hasLength(1));
  });

  test('a disabled bearer repeats nothing', () async {
    enabled = false;
    hear(msg);
    await advance(2000);
    expect(aired, isEmpty);
  });

  // ── 13.2.2: the sender names the relays ────────────────────────────────
  group('a named path', () {
    const asked = 'relay:$self,X3NEXT';

    test('we relay when we are the hop asked for next', () async {
      hear('t:message f:X1AAAA d:X1BBBB ts:$ts $asked m:go');
      await advance(2000);
      expect(aired, hasLength(1));
      expect(aired.single, contains('via:$self'));
      expect(aired.single, contains(asked),
          reason: 'relay: must travel unchanged — it is inside the identifier');
    });

    test('we stay quiet when the path does not name us', () async {
      hear('t:message f:X1AAAA d:X1BBBB ts:$ts relay:X9OTHER,X3NEXT m:go');
      await advance(2000);
      expect(aired, isEmpty);
    });

    test('we stay quiet when named but not yet our turn', () async {
      hear('t:message f:X1AAAA d:X1BBBB ts:$ts relay:X9FIRST,$self m:go');
      await advance(2000);
      expect(aired, isEmpty, reason: 'jumped the queue');
    });

    test('our turn arrives once the earlier hop has taken it', () async {
      hear('t:message f:X1AAAA d:X1BBBB ts:$ts relay:X9FIRST,$self '
          'via:X9FIRST m:go');
      await advance(2000);
      expect(aired, hasLength(1));
      expect(aired.single, contains('via:X9FIRST,$self'));
    });

    test('a spent path is a terminal state: nobody relays', () async {
      hear('t:message f:X1AAAA d:X1BBBB ts:$ts relay:X9FIRST,X9SECOND '
          'via:X9FIRST,X9SECOND m:go');
      await advance(2000);
      expect(aired, isEmpty);
    });

    test('the suffix is part of the callsign (3.1)', () async {
      // X3SELF-9 is a different device. Naming it must not fire here.
      hear('t:message f:X1AAAA d:X1BBBB ts:$ts relay:$self-9 m:go');
      await advance(2000);
      expect(aired, isEmpty);
    });
  });

  test('the queue is bounded', () async {
    for (var i = 0; i < XprsDigipeater.maxQueue + 4; i++) {
      hear('t:message f:X1AAAA d:X1BBBB ts:$ts m:filler $i');
    }
    expect(d.dropped, 4);
    await advance(2000);
    expect(aired, hasLength(XprsDigipeater.maxQueue));
  });

  group('the medium it heard it on (13.1)', () {
    // The rule this class is named for, and the one it could not implement
    // until `heard` took a bearer: the only caller matched `b.name != 'ble5'`
    // and repeated everything onto Bluetooth, wherever it came from.
    test('a packet heard on the LAN is repeated onto the LAN', () async {
      hear(msg, 'lan');
      await advance(2000);
      expect(lanes, ['lan']);
    });

    test('a packet heard on BLE is repeated onto BLE', () async {
      hear(msg, 'ble');
      await advance(2000);
      expect(lanes, ['ble']);
    });

    test('the same packet on two media is repeated on each', () async {
      // Two separate hearings, two separate rooms: repeating onto Bluetooth
      // does nothing for the machines on the LAN, so "already aired" is a fact
      // about a lane and not about the packet.
      hear(msg, 'ble');
      hear(msg, 'lan');
      await advance(2000);
      expect(lanes.toSet(), {'ble', 'lan'});
      expect(aired.length, 2);
    });

    test('a medium switched off does not repeat, and does not block others',
        () async {
      d.enabled = (lane) => lane != 'lan';
      hear(msg, 'lan');
      hear(msg, 'ble');
      await advance(2000);
      expect(lanes, ['ble']);
    });
  });
}
