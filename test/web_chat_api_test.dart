// The station API a visitor's browser gets from this phone: public rows out,
// a visitor's own signed wire in, and the rules that keep the phone's owner
// out of it (XPRS.md 4, 5, 6.1; spec/API-HTTP.md).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/ecc/curves/secp256k1.dart';
import 'package:xprs/services/web_chat_api.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';

final BigInt _d = BigInt.parse('1234567890abcdef1234567890abcdef', radix: 16);

Uint8List _pubOf(BigInt d) {
  final q = (ECCurve_secp256k1().G * d)!;
  final x = q.x!.toBigInteger()!.toRadixString(16).padLeft(64, '0');
  return Uint8List.fromList(
      [for (var i = 0; i < 64; i += 2) int.parse(x.substring(i, i + 2), radix: 16)]);
}

String _signed(String wire, {BigInt? key}) =>
    xprsSign(XprsPacket.parse(wire)!, key ?? _d).encode();

void main() {
  late List<String> received;
  late List<Map<String, dynamic>> asked;
  late DateTime clock;
  Uint8List? known;
  var allow = true;

  WebChatApi make() => WebChatApi(
        publicRows: ({sinceMs, untilMs, required types, from, visitor, room, required limit}) {
          asked.add({'types': types, 'from': from, 'limit': limit, 'since': sinceMs, 'visitor': visitor, 'room': room});
          return [
            {'type': 'message', 'from': 'X1AAA', 'to': '', 'own': false, 'wire': 'a'},
            {'type': 'message', 'from': 'X1SELF', 'to': '', 'own': true, 'wire': 'b'},
          ];
        },
        held: (t) => 7,
        receive: received.add,
        mayAir: (_) => allow,
        selfCallsign: () => 'X1SELF',
        keyOf: (c) => known,
        appPath: () => '/app',
        now: () => clock,
      );

  setUp(() {
    received = [];
    asked = [];
    known = null;
    allow = true;
    clock = DateTime.utc(2026, 10, 15, 12);
  });

  Future<WebChatReply> send(WebChatApi a, String wire, {String peer = 'p1'}) =>
      a.handle('POST', '/api/xprs/send', {}, wire, peer: peer);

  const msg = 't:message f:X3ABCD ts:2026-10-15_12:00:00 scope:local m:hello';

  group('what a visitor reads', () {
    test('room= asks one chat room; anything else asks none', () async {
      final a = make();
      await a.handle('GET', '/api/xprs/history', {'kind': 'message', 'room': 'local'}, '');
      await a.handle('GET', '/api/xprs/history', {'kind': 'message', 'room': 'x'}, '');
      expect(asked.map((q) => q['room']).toList(), ['local', null]);
    });

    test('only conversation types, newest rows, a capped limit', () async {
      final a = make();
      final r = await a.handle('GET', '/api/xprs/history',
          {'kind': 'message,command,mailbox,status', 'limit': '9999'}, '');
      expect(r.status, 200);
      expect(asked.single['types'], ['message', 'status'],
          reason: 'a command or a mailbox is machinery, not conversation');
      expect(asked.single['limit'], WebChatApi.maxLimit);
      expect(r.json['held'], 7);
      expect((r.json['rows'] as List), hasLength(2));
    });

    test('asking for nothing readable gets conversation, never everything',
        () async {
      final a = make();
      await a.handle('GET', '/api/xprs/history', {'kind': 'command'}, '');
      expect(asked.single['types'], WebChatApi.readable.toList());
    });

    test('dir and call narrow the rows, epoch or stamp as since', () async {
      final a = make();
      final out = await a.handle(
          'GET', '/api/xprs/history', {'dir': 'out', 'call': 'X1SELF', 'since': '1790000000'}, '');
      expect((out.json['rows'] as List).single['from'], 'X1SELF');
      expect(asked.single['from'], 'X1SELF');
      expect(asked.single['since'], 1790000000 * 1000);
      await a.handle('GET', '/api/xprs/history',
          {'since': '2026-10-15_12:00:00'}, '');
      expect(asked.last['since'], DateTime.utc(2026, 10, 15, 12).millisecondsSinceEpoch);
    });

    test('services says which tabs and where the app is', () async {
      final r = await make().handle('GET', '/api/services', {}, '');
      final page = r.json['page'] as Map;
      expect(page['tabs'], ['chat', 'traffic']);
      expect(page['config'], false);
      expect(page['session'], true);
      expect(page['app'], '/app');
    });

    test('anything else is not here', () async {
      final a = make();
      for (final p in ['/api/xprs/bearers', '/api/status', '/api/wifi', '/api/log']) {
        expect((await a.handle('GET', p, {}, '')).status, 404, reason: p);
      }
      expect((await a.handle('POST', '/api/xprs/history', {}, '')).status, 404);
    });
  });

  group('a visitor proves a callsign before reading its mail', () {
    Future<String> nonce(WebChatApi a, {String peer = 'p1'}) async =>
        (await a.handle('GET', '/api/session', {}, '', peer: peer)).json['nonce'] as String;

    String proof(String n, {String call = 'X3ABCD', BigInt? key}) =>
        _signed('t:session f:$call ts:2026-10-15_12:00:00 m:$n', key: key);

    test('the right key gets a session, and history then names the visitor',
        () async {
      final a = make();
      known = _pubOf(_d);
      final n = await nonce(a);
      final r = await a.handle('POST', '/api/session', {}, proof(n), peer: 'p1');
      expect(r.status, 200);
      final token = r.json['session'] as String;
      expect(a.sessionCall(token), 'X3ABCD');
      await a.handle('GET', '/api/xprs/history', {'session': token}, '');
      expect(asked.last['visitor'], 'X3ABCD');
      await a.handle('GET', '/api/xprs/history', {}, '');
      expect(asked.last['visitor'], isNull, reason: 'no session, no mail');
      await a.handle('GET', '/api/xprs/history', {'session': 'not-a-token'}, '');
      expect(asked.last['visitor'], isNull);
    });

    test('a callsign written by somebody who does not hold its key gets nothing',
        () async {
      final a = make();
      known = _pubOf(_d);
      final other = BigInt.parse('abcdefabcdefabcdefabcdefabcdefab', radix: 16);
      final n = await nonce(a);
      final r = await a.handle('POST', '/api/session', {}, proof(n, key: other), peer: 'p1');
      expect(r.status, 403);
      expect(r.json.containsKey('session'), isFalse);
    });

    test('with no key heard yet the answer is to send the identity first',
        () async {
      final a = make();
      final n = await nonce(a);
      final r = await a.handle('POST', '/api/session', {}, proof(n), peer: 'p1');
      expect(r.status, 409);
      // The challenge survives the identity arriving, then works once.
      known = _pubOf(_d);
      expect((await a.handle('POST', '/api/session', {}, proof(n), peer: 'p1')).status, 200);
      expect((await a.handle('POST', '/api/session', {}, proof(n), peer: 'p1')).status, 403,
          reason: 'a nonce is good once');
    });

    test('a nonce and a session both run out', () async {
      final a = make();
      known = _pubOf(_d);
      final n = await nonce(a);
      clock = clock.add(WebChatApi.nonceLife + const Duration(seconds: 1));
      expect((await a.handle('POST', '/api/session', {}, proof(n), peer: 'p1')).status, 403);
      final n2 = await nonce(a);
      final token = (await a.handle('POST', '/api/session', {}, proof(n2), peer: 'p1'))
          .json['session'] as String;
      clock = clock.add(WebChatApi.sessionLife + const Duration(seconds: 1));
      expect(a.sessionCall(token), isNull);
    });

    test('a made-up challenge is refused', () async {
      final a = make();
      known = _pubOf(_d);
      expect((await a.handle('POST', '/api/session', {}, proof('deadbeef'), peer: 'p1')).status, 403);
    });
  });

  group('what a visitor sends', () {
    test('a signed wire goes to the receive door, and only there', () async {
      final a = make();
      final wire = _signed(msg);
      final r = await send(a, wire);
      expect(r.status, 200);
      expect(r.json['ok'], true);
      expect((r.json['id'] as String), hasLength(6));
      expect(received, [wire]);
    });

    test('JSON, form and GET carry the same wire', () async {
      final a = make();
      final wire = _signed(msg);
      expect((await send(a, '{"wire":"${wire.replaceAll('"', r'\"')}"}')).status, 200);
      clock = clock.add(const Duration(seconds: 5));
      expect((await a.handle('POST', '/api/xprs/send', {},
              'wire=${Uri.encodeQueryComponent(wire)}', peer: 'p1')).status, 200);
      clock = clock.add(const Duration(seconds: 5));
      expect((await a.handle('GET', '/api/xprs/send', {'wire': wire}, '', peer: 'p1')).status, 200);
    });

    test('never as this station, whatever the signature', () async {
      final a = make();
      final r = await send(a, _signed(msg.replaceFirst('X3ABCD', 'X1SELF')));
      expect(r.status, 403);
      final sub = await send(a, _signed(msg.replaceFirst('X3ABCD', 'X1SELF-2')));
      expect(sub.status, 403, reason: "the owner's other device is the owner too");
      expect(received, isEmpty);
    });

    test('unsigned is refused, so the phone never signs for a visitor', () async {
      final r = await send(make(), msg);
      expect(r.status, 400);
      expect(r.json['error'], 'unsigned');
    });

    test('a forged signature is refused once the key is known', () async {
      final a = make();
      known = _pubOf(_d);
      final other = BigInt.parse('abcdefabcdefabcdefabcdefabcdefab', radix: 16);
      expect((await send(a, _signed(msg, key: other))).status, 400);
      expect((await send(a, _signed(msg))).status, 200,
          reason: 'the right key still passes');
    });

    test('a visitor posts conversation and an identity, nothing else', () async {
      final a = make();
      for (final t in ['command', 'moderate', 'mailbox', 'receipt', 'observation']) {
        final w = _signed('t:$t f:X3ABCD ts:2026-10-15_12:00:00 m:x');
        expect((await send(a, w, peer: 'p-$t')).status, 403, reason: t);
      }
      final id = _signed('t:identity f:X3ABCD ts:2026-10-15_12:00:00 m:x');
      expect((await send(a, id, peer: 'p-id')).status, 200);
    });

    test('malformed and over-long are refused', () async {
      final a = make();
      expect((await send(a, 'hello')).status, 400);
      expect((await send(a, 't:message m:no sender')).status, 400);
      expect((await send(a, _signed('$msg ${'x' * 300}'))).status, 400);
    });

    test("a closed group this phone is not in is not the visitor's to post to",
        () async {
      allow = false;
      final r = await send(make(), _signed(msg.replaceFirst('f:X3ABCD', 'f:X3ABCD d:X5A3F2')));
      expect(r.status, 403);
    });

    test('a visitor cannot flood: a burst, then a pace, then a minute cap',
        () async {
      final a = make();
      var ok = 0, slow = 0;
      for (var i = 0; i < 12; i++) {
        final r = await send(a, _signed(msg.replaceFirst('hello', 'm$i')));
        if (r.status == 200) ok++;
        if (r.status == 429) slow++;
      }
      expect(ok, WebChatApi.burst);
      expect(slow, 12 - WebChatApi.burst);
      // Another visitor is not slowed by the first.
      expect((await send(a, _signed(msg), peer: 'p2')).status, 200);
      // A minute later the first may talk again.
      clock = clock.add(const Duration(seconds: 61));
      expect((await send(a, _signed(msg.replaceFirst('hello', 'again')))).status, 200);
    });

    test('visitors are counted by address', () async {
      final a = make();
      await a.handle('GET', '/api/services', {}, '', peer: '10.0.0.2');
      await a.handle('GET', '/api/services', {}, '', peer: '10.0.0.3');
      await a.handle('GET', '/api/services', {}, '', peer: '10.0.0.2');
      expect(a.visitors, {'10.0.0.2', '10.0.0.3'});
    });
  });
}
