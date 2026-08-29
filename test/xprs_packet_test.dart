// The specification is the test corpus.
//
// `test/xprs_corpus.json` holds every example packet in `docs/XPRS.md`, the
// byte count the document claims for it, and the identifier computed by the
// independent Python harness that has checked that document all along.
//
// So these tests do not assert that the codec agrees with itself. They assert
// that it agrees with the specification, and with a second implementation
// written in another language. That is the only kind of agreement that matters
// for a wire format.
//
// The AUTHORITATIVE corpus lives in the spec's own repository
// (github.com/xprs-dev/spec, xprs_corpus.json); this file is the consumed
// copy. On a machine that has the spec repo checked out beside this one, the
// drift test below fails if the two ever differ — CI, which clones only this
// repo, skips it.

import 'dart:convert';
import 'dart:io';

import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_vocab.dart';
import 'package:flutter_test/flutter_test.dart';

List<Map<String, dynamic>> _corpus() {
  final f = File('test/xprs_corpus.json');
  return (jsonDecode(f.readAsStringSync()) as List).cast<Map<String, dynamic>>();
}

// ── Only a person's text reaches a person ────────────────────────────────
//
// The mesh is mostly machines: on a four-station bench, 176 observations and
// 105 catch-up commands against 15 messages. All of it must cross the air —
// that is what a mesh is — and almost none of it belongs on a screen. This is
// the rule that decides, and it is tested here rather than through
// MeshCourier.deliverXprs because that function needs a live Reticulum stack
// and returns false in a bare test for reasons that have nothing to do with
// the rule: a test that cannot fail for the right reason proves nothing.
void _addressesStation() {
  group('a station, or a group (6.3)', () {
    test('a closed group is not a station, however callsign-shaped', () {
      // The bug this predicate exists to end: three separate tests accepted
      // `X[1345]`, and `X5` IS the closed-group prefix (26.1).
      expect(xprsAddressesStation('X5KPGF'), isFalse);
      expect(xprsAddressesStation('x5kpgf'), isFalse);
    });

    test('nor is an open group or a broadcast', () {
      // `ROOM7` carries a digit, which is why "has a digit" is not the test:
      // the shape has to be a callsign's. `NET21` is deliberately absent —
      // 6.3 says an open group name "may not look like a callsign", so
      // anything that does is one, and treating it as a station is right.
      for (final d in ['#NEWS', '!ALL', 'LISBOA', 'ROOM7']) {
        expect(xprsAddressesStation(d), isFalse, reason: d);
      }
    });

    test('a station is, in every shape section 3 allows', () {
      for (final d in ['X1RD89', 'X1RD89-2', 'X3ARK', 'CT1ABC-9', 'CT1ABC/P']) {
        expect(xprsAddressesStation(d), isTrue, reason: d);
      }
    });

    test('absent is not a station — a broadcast has nobody to address', () {
      expect(xprsAddressesStation(''), isFalse);
      expect(xprsAddressesStation(null), isFalse);
      expect(xprsAddressesStation('   '), isFalse);
    });
  });
}

void _rendersToPerson() {
  XprsPacket pkt(String w) => XprsPacket.parse(w)!;
  const ts = '2026-08-28_09:00:00';

  group('what a person is shown', () {
    test('a message is', () {
      expect(xprsRendersToPerson(pkt('t:message f:X3ARK d:X16JK8 ts:$ts '
              'm:are you there')),
          isTrue);
    });

    test('a post to a closed group is NOT — it is nobody\'s correspondence',
        () {
      // 26.1: `d:` is the GROUP. The courier that ends in the chat inbox keys
      // the thread on the SENDER, so this arrived as a private message from
      // whoever happened to post it. Measured on the bench.
      expect(
          xprsRendersToPerson(pkt('t:message f:X16JK8 d:X5KPGF ts:$ts '
              'm:net at six')),
          isFalse);
    });

    test('nor is an open group, nor an undirected post', () {
      expect(
          xprsRendersToPerson(
              pkt('t:message f:X3ARK d:LISBOA ts:$ts m:anyone about')),
          isFalse);
      expect(
          xprsRendersToPerson(
              pkt('t:message f:X3ARK ts:$ts scope:local m:anyone about')),
          isFalse);
    });

    test('a station keeps every shape section 3 allows', () {
      for (final d in ['X1RD89', 'X1RD89-2', 'X3ARK', 'CT1ABC-9']) {
        expect(xprsRendersToPerson(pkt('t:message f:X3ARK d:$d ts:$ts m:hi')),
            isTrue,
            reason: '$d is a station');
      }
    });

    test('a catch-up ask is not', () {
      expect(
          xprsRendersToPerson(pkt('t:command f:X3ARK d:X16JK8 ts:$ts '
              'cmd:history kind:message since:2026-08-26_20:22:14')),
          isFalse);
    });

    test('a result is not, even carrying m:', () {
      // The one machine type with an m: field — the one that would otherwise
      // have arrived as a bubble reading "try X1AAAA,X1BBBB".
      expect(
          xprsRendersToPerson(pkt('t:result f:X3ARK d:X16JK8 ts:$ts '
              'r:9f2c41 code:404 m:try X1AAAA,X1BBBB')),
          isFalse);
    });

    test('an observation is not, even carrying m:', () {
      expect(
          xprsRendersToPerson(pkt('t:observation f:X3ARK ts:$ts link:ble '
              'peers:2 m:on the hill')),
          isFalse);
    });

    test('a receipt and an identity are not', () {
      expect(
          xprsRendersToPerson(
              pkt('t:receipt f:X3ARK d:X16JK8 ts:$ts r:9f2c41 s:ack')),
          isFalse);
      expect(
          xprsRendersToPerson(pkt('t:identity f:X3ARK ts:$ts k:npub1abc')),
          isFalse);
    });

    test('sos and warning are not couriered — 13.1 airs them', () {
      // A person wants both. They reach people by being HEARD, with nine
      // relays, not by being delivered into an inbox.
      expect(xprsRendersToPerson(pkt('t:sos f:X3ARK ts:$ts m:help')), isFalse);
      expect(xprsRendersToPerson(pkt('t:warning f:X3ARK ts:$ts m:fire')),
          isFalse);
    });
  });
}

void main() {
  _addressesStation();
  _rendersToPerson();
  group('the XPRS codec against the specification', () {
    final corpus = _corpus();

    test('the corpus is actually there', () {
      expect(corpus.length, greaterThan(150));
    });

    test('the consumed copy matches the authoritative one, when present', () {
      final official = File('../../xprs/spec/xprs_corpus.json');
      if (!official.existsSync()) {
        markTestSkipped('spec repo not checked out beside this one');
        return;
      }
      expect(File('test/xprs_corpus.json').readAsStringSync(),
          official.readAsStringSync(),
          reason: 'test/xprs_corpus.json has drifted from the spec repo — '
              'update both together');
    });

    test('every packet in the document parses', () {
      final bad = <String>[];
      for (final c in corpus) {
        if (XprsPacket.parse(c['wire'] as String) == null) {
          bad.add(c['wire'] as String);
        }
      }
      expect(bad, isEmpty, reason: 'these did not parse:\n${bad.join('\n')}');
    });

    test('every packet round-trips to the byte', () {
      final bad = <String>[];
      for (final c in corpus) {
        final w = c['wire'] as String;
        final got = XprsPacket.parse(w)!.encode();
        if (got != w) bad.add('$w\n  became $got');
      }
      expect(bad, isEmpty, reason: 'round-trip changed:\n${bad.join('\n')}');
    });

    test('every stated byte count is what the codec measures', () {
      final bad = <String>[];
      for (final c in corpus) {
        final want = c['bytes'] as int?;
        if (want == null) continue;
        final got = XprsPacket.parse(c['wire'] as String)!.byteLength;
        if (got != want) bad.add('${c['wire']}\n  doc $want, codec $got');
      }
      expect(bad, isEmpty, reason: 'byte counts disagree:\n${bad.join('\n')}');
    });

    test('nothing in the document exceeds the 250-byte limit', () {
      for (final c in corpus) {
        expect(XprsPacket.parse(c['wire'] as String)!.fits, isTrue,
            reason: c['wire'] as String);
      }
    });

    test('identifiers agree with the independent implementation', () {
      final bad = <String>[];
      for (final c in corpus) {
        final got = xprsIdentifier(XprsPacket.parse(c['wire'] as String)!);
        if (got != c['id']) bad.add('${c['wire']}\n  py ${c['id']}, dart $got');
      }
      expect(bad, isEmpty, reason: 'identifiers disagree:\n${bad.join('\n')}');
    });

    test('m: is last wherever it appears', () {
      // Everything after `m:` is the message, so a field after it would be
      // swallowed. Five packets in the document once had `sig:` there.
      for (final c in corpus) {
        final p = XprsPacket.parse(c['wire'] as String)!;
        final at = p.fields.indexWhere((f) => f.key == 'm');
        if (at >= 0) {
          expect(at, p.fields.length - 1, reason: c['wire'] as String);
        }
      }
    });

    test('every packet declares its type first', () {
      for (final c in corpus) {
        expect(XprsPacket.parse(c['wire'] as String)!.fields.first.key, 't',
            reason: c['wire'] as String);
      }
    });
  });

  group('parsing rules', () {
    test('a packet that does not start with t: is not XPRS', () {
      expect(XprsPacket.parse('f:X1QZ3N t:message m:hello'), isNull);
      expect(XprsPacket.parse('X1A33TX1RD89am:40c124'), isNull);
      expect(XprsPacket.parse(''), isNull);
    });

    test('an unknown key is kept, not dropped', () {
      // Design rule 8: unknown keys are skipped by a *reader*, but the codec
      // must preserve them or relaying a packet would silently strip fields
      // the next station might understand.
      final p = XprsPacket.parse('t:message f:X1QZ3N zpm:8 m:hi')!;
      expect(p['zpm'], '8');
      expect(p.encode(), 't:message f:X1QZ3N zpm:8 m:hi');
    });

    test('a malformed field is skipped and the rest still reads', () {
      final p = XprsPacket.parse('t:message f:X1QZ3N NOTAFIELD d:LISBOA m:hi')!;
      expect(p['f'], 'X1QZ3N');
      expect(p['d'], 'LISBOA');
    });

    test('m: takes everything after it, spaces and colons included', () {
      final p = XprsPacket.parse('t:message f:X1QZ3N m:see http://x.y/z now')!;
      expect(p['m'], 'see http://x.y/z now');
      expect(p.fields.length, 3);
    });

    test('a key is at most eight characters, letters and digits', () {
      final p = XprsPacket.parse('t:message f:X1QZ3N toolongkey:1 rain24:3 m:x')!;
      expect(p['toolongkey'], isNull);
      expect(p['rain24'], '3');
    });

    test('byteLength counts UTF-8, not characters', () {
      final p = XprsPacket.parse('t:message f:CT1ABC m:ate logo')!;
      final q = XprsPacket.parse('t:message f:CT1ABC m:até logo')!;
      expect(q.byteLength, p.byteLength + 1);
    });

    test('with_ inserts before m: so the message stays last', () {
      final p = XprsPacket.parse('t:message f:X1QZ3N m:hi')!;
      expect(p.with_('d', 'LISBOA').encode(),
          't:message f:X1QZ3N d:LISBOA m:hi');
    });
  });

  group('transport vocabulary', () {
    test('relay budget comes from the type', () {
      expect(xprsRelayLimit('sos'), 9);
      expect(xprsRelayLimit('warning'), 9);
      expect(xprsRelayLimit('message'), 3);
      expect(xprsRelayLimit('status'), 3);
    });

    test('hop count is the length of via:, and bounds relaying', () {
      final p = XprsPacket.parse(
          't:message f:X1QZ3N via:X32DVA,CT1ABC-9,X3RLY7 m:x')!;
      expect(xprsVia(p).length, 3);
      expect(xprsMayRelay(p), isFalse);
      expect(xprsMayRelay(XprsPacket.parse('t:message f:X1QZ3N m:x')!), isTrue);
    });

    test('a station that finds itself in via: does not relay', () {
      final p = XprsPacket.parse('t:message f:X1QZ3N via:X32DVA m:x')!;
      expect(xprsWouldLoop(p, 'X32DVA'), isTrue);
      expect(xprsWouldLoop(p, 'x32dva'), isTrue);
      expect(xprsWouldLoop(p, 'X3RLY7'), isFalse);
    });

    test('appending via: changes neither the identifier nor the signed text',
        () {
      final p = XprsPacket.parse('t:message f:X1QZ3N d:X1RD89 m:x')!;
      final relayed = xprsAppendVia(p, 'X32DVA');
      expect(relayed['via'], 'X32DVA');
      expect(xprsIdentifier(relayed), xprsIdentifier(p));
      expect(xprsAppendVia(relayed, 'X3RLY7')['via'], 'X32DVA,X3RLY7');
    });

    test('a local packet is never carried', () {
      expect(
          xprsMayCarry(XprsPacket.parse('t:message f:X1QZ3N scope:local m:x')!),
          isFalse);
      expect(xprsMayCarry(XprsPacket.parse('t:message f:X1QZ3N m:x')!), isTrue);
      expect(
          xprsMayCarry(XprsPacket.parse('t:message f:X1QZ3N scope:PT,ES m:x')!),
          isTrue);
    });

    test('urgency parses the XPRS words and never drops on a bad one', () {
      expect(XprsUrgency.fromWire('urgent'), XprsUrgency.urgent);
      expect(XprsUrgency.fromWire('LOW'), XprsUrgency.low);
      expect(XprsUrgency.fromWire('nonsense'), XprsUrgency.normal);
      expect(XprsUrgency.fromWire(null), XprsUrgency.normal);
    });

    test('a stated urgency is capped, so nobody talks their way to the front',
        () {
      expect(XprsUrgency.urgent.cappedAt(XprsUrgency.high), XprsUrgency.high);
      expect(XprsUrgency.low.cappedAt(XprsUrgency.high), XprsUrgency.low);
    });

    test('a channel reading without link: is unusable', () {
      expect(
          xprsReadingIsScoped(
              XprsPacket.parse('t:observation f:X3RLY7 busy:41%')!),
          isFalse);
      expect(
          xprsReadingIsScoped(
              XprsPacket.parse('t:observation f:X3RLY7 link:lora busy:41%')!),
          isTrue);
      expect(
          xprsReadingIsScoped(
              XprsPacket.parse('t:observation f:X3RLY7 link:moon busy:41%')!),
          isFalse);
      expect(
          xprsReadingIsScoped(
              XprsPacket.parse('t:observation f:X3RLY7 temp:14.2C')!),
          isTrue);
    });
  });
}
