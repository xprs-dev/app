// The decoration of XPRS.md 6.3.2 (a name, a picture, a line), both halves:
// the packets this station composes, and what a receiver keeps of them. The
// receiver is the core's XprsProfiles with its seams injected: no archive, no
// node, no radio. The fetch policy is the budget a shared channel can afford.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_profiles.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/services/xprs/xprs_vocab.dart';
import 'package:xprs/util/media_ref.dart';
import 'package:xprs/util/nostr_crypto.dart';

typedef _Key = ({BigInt d, Uint8List pub});

_Key _key() {
  final kp = NostrCrypto.generateKeyPair();
  var d = BigInt.zero;
  for (final b in HEX.decode(kp.privateKeyHex)) {
    d = (d << 8) | BigInt.from(b);
  }
  return (d: d, pub: Uint8List.fromList(HEX.decode(kp.publicKeyHex)));
}

const _pic = 'file:nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg';
const _pic2 = 'file:AAAAAGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w.jpg';

List<String> _deco(_Key k,
        {String call = 'X1QZ3N',
        String nick = 'joao',
        String file = _pic,
        String about = 'sailing the Algarve coast',
        String ts = '2026-08-08_14:26:40'}) =>
    XprsPublisher.composeDecoration(
        call: call, nick: nick, fileToken: file, about: about, ts: ts,
        signingKey: k.d);

int _bytes(String w) => utf8.encode(w).length;

void main() {
  group('composing (6.3.2)', () {
    test('a short decoration is one signed packet', () {
      final k = _key();
      final w = _deco(k, about: 'sailing');
      expect(w, hasLength(1));
      final p = XprsPacket.parse(w.single)!;
      expect(p['nick'], 'joao');
      expect(p['file'], _pic.substring(5));
      expect(p['m'], 'sailing');
      expect(p.has('k'), isFalse, reason: 'the key binding is its own packet');
      expect(p.has('scope'), isFalse);
      expect(_bytes(w.single),
          lessThanOrEqualTo(XprsPublisher.decorationFrameMax));
      expect(xprsVerify(p, k.pub), XprsSigState.verified);
    });

    test("the spec's 198-byte example is two packets, each for any bearer",
        () {
      // 6.3.2's worked packet is 198 B; the smallest controller carries 184
      // (ble5.md 3). "Any subset of these fields" lets it be two.
      final k = _key();
      final w = _deco(k);
      expect(w, hasLength(2));
      expect(XprsPacket.parse(w[0])!['file'], _pic.substring(5));
      expect(XprsPacket.parse(w[1])!['m'], 'sailing the Algarve coast');
      for (final x in w) {
        expect(_bytes(x), lessThanOrEqualTo(XprsPublisher.decorationFrameMax));
        expect(xprsVerify(XprsPacket.parse(x)!, k.pub), XprsSigState.verified);
      }
    });

    test('too much for one frame: picture and name first, the line alone', () {
      final k = _key();
      final w = _deco(k,
          call: 'MT0C39F654',
          nick: 'a-rather-long-nickname',
          about: List.filled(40, 'words').join(' '));
      expect(w, hasLength(2));
      final a = XprsPacket.parse(w[0])!, b = XprsPacket.parse(w[1])!;
      expect(_bytes(w[0]), lessThanOrEqualTo(XprsPublisher.decorationFrameMax),
          reason: 'the smallest BLE controller carries 184 B (ble5.md 3)');
      expect(a['file'], _pic.substring(5), reason: 'the picture never drops');
      expect(a['nick']!.length, lessThanOrEqualTo(16));
      expect(b.has('file'), isFalse);
      expect(b['m'], isNotEmpty);
      expect(_bytes(w[1]), lessThanOrEqualTo(XprsPacket.maxBytes));
      for (final p in [a, b]) {
        expect(p['f'], 'MT0C39F654');
        expect(xprsVerify(p, k.pub), XprsSigState.verified);
      }
    });

    test('nothing set is said as "-", so a removal reaches the peers', () {
      final w = _deco(_key(), nick: '', file: '', about: '');
      final p = XprsPacket.parse(w.single)!;
      expect(p['nick'], '-');
      expect(p['file'], '-');
      expect(p['m'], '-');
    });

    test('no key, no decoration: an unsigned one is a claim by nobody', () {
      expect(
          XprsPublisher.composeDecoration(
              call: 'X1QZ3N', nick: 'joao', fileToken: _pic, about: 'x',
              ts: '2026-08-08_14:26:40', signingKey: null),
          isEmpty);
    });

    test('a display name becomes a 6.3.1 nickname', () {
      expect(xprsNickValue('João Sá Barco'), 'Joao-Sa-Barco');
      expect(xprsNickValue('  ¡hola!  '), 'hola');
      expect(xprsNickValue('abcdefghijklmnopqrstuvwxyz').length, 16);
      expect(xprsNickValue('日本'), '');
    });
  });

  group('receiving (6.3.2)', () {
    late XprsProfiles r;
    late _Key k;
    final asked = <String>[];
    var known = true;
    final held = <String>{};

    setUp(() {
      r = XprsProfiles.instance;
      k = _key();
      asked.clear();
      held.clear();
      known = true;
      r.keyResolver = (c) => c == 'X1QZ3N' ? k.pub : null;
      r.identityRows = (c) => const [];
      r.isKnown = (c) => known;
      r.holds = held.contains;
      r.fetch = (ref, from) async {
        asked.add(ref.sha256);
        return false;
      };
    });

    XprsPacket p(String w) => XprsPacket.parse(w)!;
    void offerAll(String c, List<String> ws) {
      for (final w in ws) {
        r.offer(c, p(w));
      }
    }

    test('a verified decoration is kept, and a known station is fetched', () {
      final c = 'X1QZ3N';
      for (final w in _deco(k)) {
        r.offer(c, p(w));
      }
      expect(r.nickFor(c), 'joao');
      expect(r.aboutFor(c), 'sailing the Algarve coast');
      expect(r.pictureFor(c)?.token, _pic);
      expect(asked, [MediaRef.parse(_pic)!.sha256]);
    });

    test('newest per field wins, and an older one never comes back', () {
      final c = 'X1QZ3N';
      offerAll(c, _deco(k, file: _pic2, ts: '2026-09-01_00:00:00'));
      offerAll(c, _deco(k, nick: 'old', ts: '2026-08-01_00:00:00'));
      expect(r.pictureFor(c)?.token, _pic2);
      expect(r.nickFor(c), isNot('old'));
      // file:- clears it, and only a newer picture brings one back.
      offerAll(c, _deco(k, file: '', ts: '2026-09-02_00:00:00'));
      expect(r.pictureFor(c), isNull);
      offerAll(c, _deco(k, file: _pic, ts: '2026-09-01_12:00:00'));
      expect(r.pictureFor(c), isNull, reason: 'older than the removal');
    });

    test('a forged decoration and an unknown signer are ignored', () {
      final other = _key();
      offerAll('X1QZ3N', _deco(other, ts: '2026-10-01_00:00:00', nick: 'mallory'));
      expect(r.nickFor('X1QZ3N'), isNot('mallory'));
      offerAll('X1NOBODY', _deco(other, call: 'X1NOBODY'));
      expect(r.decorationFor('X1NOBODY')?.nick, isNull);
    });

    test('a decoration heard before the key is read again once it is bound',
        () {
      final late = _key();
      final ws = _deco(late, call: 'X1LATE', ts: '2026-10-03_00:00:00');
      Uint8List? lateKey;
      r.keyResolver = (c) => c == 'X1LATE' ? lateKey : null;
      r.identityRows = (c) =>
          c == 'X1LATE'
              ? [for (final w in ws) {'wire': w, 'sig': 'unverified'}]
              : const [];
      offerAll('X1LATE', ws);
      expect(r.nickFor('X1LATE'), isNull);
      lateKey = late.pub;
      r.keyLearned('X1LATE');
      expect(r.nickFor('X1LATE'), 'joao');
    });

    test("a stranger's picture waits for a screen, on a budget", () async {
      known = false;
      final callers = <String>[];
      for (var i = 0; i < 14; i++) {
        final kk = _key();
        final c = 'X1S${i.toString().padLeft(3, '0')}';
        r.keyResolver = (x) => x == c ? kk.pub : null;
        final file = 'file:${'S$i'.padRight(43, 'x')}.jpg';
        offerAll(c, _deco(kk, call: c, file: file,
            ts: '2026-10-04_00:00:${i.toString().padLeft(2, '0')}'));
        callers.add(c);
      }
      expect(asked, isEmpty, reason: 'nobody asked to see them');
      for (final c in callers) {
        r.wantPicture(c);
      }
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(r.strangerAsks, lessThanOrEqualTo(10));
      expect(asked.length, lessThanOrEqualTo(10));
    });
  });
}
