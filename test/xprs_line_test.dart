// The line lane's transport half (XPRS.md 13.4, 13.0.2): what `dial:` parses
// to, and that a client comes up, notices the peer leaving, and keeps the
// set it was asked for. The funnel side (what a received line does) is the
// server's `XprsTcp` path and is covered where that is.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_line.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';

void main() {
  group('XprsDial.parse (13.0.2)', () {
    test('a bare host is port 4242', () {
      final d = XprsDial.parse('arc1.example.org')!;
      expect(d.host, 'arc1.example.org');
      expect(d.port, 4242);
      expect(d.toString(), 'arc1.example.org');
    });
    test('host:port keeps the port, and says it', () {
      final d = XprsDial.parse('10.0.0.7:4243')!;
      expect(d.host, '10.0.0.7');
      expect(d.port, 4243);
      expect(d.toString(), '10.0.0.7:4243');
    });
    test('an IPv6 literal needs brackets', () {
      final d = XprsDial.parse('[fd00::1]:4242')!;
      expect(d.host, 'fd00::1');
      expect(d.port, 4242);
      expect(XprsDial.parse('fd00::1'), isNull);
    });
    test('refuses what is not a host', () {
      expect(XprsDial.parse(''), isNull);
      expect(XprsDial.parse(null), isNull);
      expect(XprsDial.parse('host:0'), isNull);
      expect(XprsDial.parse('host:99999'), isNull);
      expect(XprsDial.parse('ho st'), isNull);
      expect(XprsDial.parse('a/b'), isNull);
    });
    test('equality is by host and port', () {
      expect(XprsDial.parse('x:4242'), equals(XprsDial.parse('x')));
      expect(XprsDial.parse('x:4243'), isNot(equals(XprsDial.parse('x'))));
    });
  });

  group('XprsLineClient', () {
    late ServerSocket server;
    final accepted = <Socket>[];

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen(accepted.add);
    });

    tearDown(() async {
      for (final s in accepted) {
        s.destroy();
      }
      accepted.clear();
      await server.close();
    });

    test('comes up, writes a line, notices the peer leaving', () async {
      final up = Completer<void>();
      final down = Completer<String>();
      final c = XprsLineClient(
        callsign: 'X3ARC1',
        dial: XprsDial('127.0.0.1', server.port),
      )
        ..onUp = up.complete
        ..onDown = down.complete;
      expect(c.send('t:ping f:X1QZ3N'), isFalse, reason: 'no socket yet');
      await c.open();
      await up.future.timeout(const Duration(seconds: 5));
      expect(c.connected, isTrue);
      expect(c.send('t:ping f:X1QZ3N d:X3ARC1'), isTrue);
      // Give the server its byte.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(accepted, hasLength(1));
      accepted.single.destroy();
      final why = await down.future.timeout(const Duration(seconds: 5));
      expect(why, isNotEmpty);
      expect(c.connected, isFalse);
      expect(c.wanted, isTrue, reason: 'a drop is retried, not given up');
      c.close();
      expect(c.wanted, isFalse);
    });

    test('a refused dial is retried later, and close() stops that', () async {
      final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = free.port;
      await free.close(); // nobody listens here now
      final c = XprsLineClient(
        callsign: 'X3NONE',
        dial: XprsDial('127.0.0.1', port),
      );
      await c.open();
      expect(c.connected, isFalse);
      expect(c.status['failures'], 1);
      c.close();
      expect(c.wanted, isFalse);
    });
  });

  group('XprsLineLane', () {
    test('keeps exactly the set it is asked for', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((s) => s.destroy());
      final lane = XprsLineLane.instance;
      final d = XprsDial('127.0.0.1', server.port);
      await lane.wantAll({'X3A': d, 'X3B': d});
      expect(lane.clients.map((c) => c.callsign).toSet(), {'X3A', 'X3B'});
      await lane.wantAll({'X3B': d});
      expect(lane.clients.map((c) => c.callsign).toSet(), {'X3B'});
      lane.closeAll();
      expect(lane.clients, isEmpty);
      await server.close();
    });

    test(
        'the line bearer carries t:identity and t:mailbox to every dialled '
        'archiver (queued, so the radios still air them) and refuses other '
        'undirected wires', () async {
      final got = <String>[];
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((s) {
        s.cast<List<int>>().transform(utf8.decoder).listen((chunk) {
          got.addAll(chunk.split('\n').where((l) => l.trim().isNotEmpty));
        });
      });
      final lane = XprsLineLane.instance;
      final d = XprsDial('127.0.0.1', server.port);
      await lane.wantAll({'X3ARC': d});
      for (var i = 0; i < 50 && !lane.connectedTo('X3ARC'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(lane.connectedTo('X3ARC'), isTrue);
      final line = XprsPublisher.instance.bearers
          .firstWhere((b) => b.name == 'line');
      const id = 't:identity f:X3ME ts:2026-11-06_10:00:00 k:npub1abc';
      const decl = 't:mailbox f:X3ME ts:2026-11-06_10:00:01 hold:X3ARC';
      const status = 't:status f:X3ME ts:2026-11-06_10:00:02 m:hello';
      expect(await line.send(id, part: 0), XprsSendResult.queued);
      expect(await line.send(decl, part: 0), XprsSendResult.queued);
      expect(await line.send(status, part: 0), XprsSendResult.refused);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(got, [id, decl]);
      lane.closeAll();
      await server.close();
    });
  });
}
