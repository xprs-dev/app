// The archiver side of the line lane (XPRS.md 13.0.2), on a real socket:
// a signed line from a station whose key the archiver does not hold is
// answered (q:mail) and asked for its key (q:identity), and NOT put on the
// socket; once the key is held, the next signed line registers it and the
// archiver can deliver to it. This is the first contact that 1.4.0 never
// completed (docs/performance.md 8.23).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/services/xprs/xprs_tcp.dart';

import 'support/mail_relay_sim.dart';

void main() {

  test('a station the archiver cannot verify is asked for its key, then put '
      'on the socket once the key is held', () async {
    final sim = MailRelaySim.build(['X1AAAA', 'X3ARCH']);
    final a = sim['X1AAAA'];
    final c = sim['X3ARCH'];
    addTearDown(sim.dispose);

    await sim.as(c, () async {
      // The archiver holds its own key and, at first, not the phone's.
      var holdsA = false;
      XprsArchive.instance.keyResolver = (call) {
        final s = sim.stations[call.trim().toUpperCase()];
        if (s == null || (s == a && !holdsA)) return null;
        return Uint8List.fromList(HEX.decode(s.pubHex));
      };
      XprsTcp.selfCallsign = () => 'X3ARCH';
      addTearDown(() => XprsTcp.selfCallsign = null);

      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      const label = 'line:test';
      server.listen((s) {
        final sink = XprsTcp.attach(s, label);
        s.listen(sink, onDone: s.destroy);
      });
      addTearDown(() => XprsLinePeers.instance.unregister(label));

      final got = <String>[];
      final client = await Socket.connect('127.0.0.1', server.port);
      addTearDown(client.destroy);
      client
          .cast<List<int>>()
          .transform(utf8.decoder)
          .listen((chunk) => got.addAll(
              chunk.split('\n').where((l) => l.trim().isNotEmpty)));

      String signedByA(String wire) =>
          xprsSign(XprsPacket.parse(wire)!, a.scalar).encode();
      // Until the answers stop coming (400 ms of quiet, 5 s at most): the
      // first line runs the stores' query code for the first time, which in
      // the test VM's JIT can take longer than one fixed wait.
      Future<void> settle() async {
        var seen = -1, quiet = 0;
        for (var i = 0; i < 100 && quiet < 8; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          if (got.length == seen) {
            quiet++;
          } else {
            seen = got.length;
            quiet = 0;
          }
        }
      }

      // First contact: the phone's q:mail, signed with a key X3ARCH has
      // never seen.
      client.write('${signedByA('t:request f:X1AAAA d:X3ARCH '
          'ts:2026-11-06_12:00:00 q:mail only:X1AAAA')}\n');
      await settle();
      expect(XprsLinePeers.instance.isConnected('X1AAAA'), isFalse,
          reason: 'an unverifiable line puts nobody on the socket');
      final answers = got.map((w) => XprsPacket.parse(w)!).toList();
      expect(
          answers.any((p) =>
              p.type == 'observation' && p['mail'] == '0' && p['only'] == 'X1AAAA'),
          isTrue,
          reason: 'q:mail is answered on the socket, zero included');
      expect(answers.any((p) => p.type == 'request' && p['q'] == 'identity'),
          isTrue,
          reason: 'the archiver asks for the key it does not hold');

      // A second unverifiable line does not ask again on this connection.
      got.clear();
      client.write('${signedByA('t:request f:X1AAAA d:X3ARCH '
          'ts:2026-11-06_12:00:01 q:mail only:X1AAAA')}\n');
      await settle();
      expect(
          got.map((w) => XprsPacket.parse(w)!).where((p) => p['q'] == 'identity'),
          isEmpty);

      // The key arrived (the phone sends t:identity at line-up): the next
      // signed line registers the phone, and the archiver delivers to it.
      holdsA = true;
      got.clear();
      client.write('${signedByA('t:request f:X1AAAA d:X3ARCH '
          'ts:2026-11-06_12:00:02 q:mail only:X1AAAA')}\n');
      await settle();
      expect(XprsLinePeers.instance.isConnected('X1AAAA'), isTrue);
      expect(XprsLinePeers.instance.sendTo('X1AAAA', 't:message f:X3ARCH '
          'd:X1AAAA ts:2026-11-06_12:00:03 m:held for you'), isTrue);
      await settle();
      expect(got.any((w) => w.contains('m:held for you')), isTrue,
          reason: 'what the archiver holds goes down the socket');
    });
  });
}
