/*
 * §7's reachability test, answered where every bearer reaches.
 *
 * The core already answered `t:ping` — inside xprs_tcp.dart, on the TCP socket,
 * and nowhere else. A ping heard over BLE, LAN or Reticulum went unanswered, so
 * the chat wapp grew a `?PING`/`?PONG` dialect of its own in the compact frame,
 * with its own TTL forwarding and its own nonce, to ask a question the core
 * would not answer on the radio.
 *
 * Answering in the funnel is what makes that dialect redundant rather than
 * merely unwanted — which is the difference between deleting a feature and
 * moving it where it belonged.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

const _ts = '2026-09-02_15:00:00';
XprsPacket _p(String w) => XprsPacket.parse(w)!;

void main() {
  final aired = <({String wire, String bearer})>[];

  setUp(() {
    aired.clear();
    XprsIngest.pongsSent = 0;
    XprsIngest.onAnswerPing = (w, b) => aired.add((wire: w, bearer: b));
  });
  tearDown(() => XprsIngest.onAnswerPing = null);

  void heard(String wire, {String bearer = 'ble'}) => XprsIngest.heard(
      _p(wire), bearer: bearer, selfCallsign: 'X1SELF');

  test('a ping addressed to us is answered on the bearer it came in on', () {
    final ping = 't:ping f:X1QZ3N d:X1SELF ts:$_ts';
    heard(ping, bearer: 'ble');
    expect(aired.length, 1);
    final pong = XprsPacket.parse(aired.single.wire)!;
    expect(pong.type, 'pong');
    expect(pong['f'], 'X1SELF');
    expect(pong['d'], 'X1QZ3N');
    expect(aired.single.bearer, 'ble',
        reason: 'the packet that just arrived is the freshest evidence of a '
            'path back (36.0)');
  });

  test('r: names the ping, so the asker needs no nonce of its own', () {
    final ping = _p('t:ping f:X1QZ3N d:X1SELF ts:$_ts');
    heard(ping.encode());
    final pong = XprsPacket.parse(aired.single.wire)!;
    expect(pong['r'], xprsIdentifier(ping));
  });

  test('an undirected ping is a question to the room, and we answer', () {
    heard('t:ping f:X1QZ3N ts:$_ts');
    expect(aired.length, 1);
  });

  test('a ping for somebody else is not ours to answer', () {
    heard('t:ping f:X1QZ3N d:X3ARK ts:$_ts');
    expect(aired, isEmpty);
    expect(XprsIngest.pongsSent, 0);
  });

  test('our own ping heard back does not answer itself', () {
    heard('t:ping f:X1SELF d:X1QZ3N ts:$_ts');
    expect(aired, isEmpty);
  });

  test('a pong is not a ping and starts no exchange', () {
    heard('t:pong f:X1QZ3N d:X1SELF ts:$_ts r:abc123');
    expect(aired, isEmpty, reason: 'answering an answer never terminates');
  });
}
