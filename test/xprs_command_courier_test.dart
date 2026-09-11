// The core delivers a command a wapp hands it (XprsCommandCourier): the wapp
// sends once, the core airs the same signed bytes again until a final answer,
// fans the copies out, and says when nothing final ever came.
import 'package:xprs/services/xprs/xprs_command_courier.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const wire = 't:command f:X1ME77 d:X3AB3D ts:2026-09-10_12:00:00 cmd:zdiag';
  const signed = '$wire sig:SIGNED';
  final c = XprsCommandCourier.instance;
  final aired = <(String, bool)>[];
  final withdrawn = <String>[];
  final reported = <(String, String)>[];
  var now = 1000000;

  setUp(() {
    c.reset();
    aired.clear();
    withdrawn.clear();
    reported.clear();
    now = 1000000;
    c.nowMs = () => now;
    c.air = (w, {required slot, required spread}) {
      aired.add((w, spread));
      return signed;
    };
    c.withdraw = withdrawn.add;
    c.report = (id, peer, state) => reported.add((id, state));
  });
  tearDown(c.reset);

  String idOf(String w) => xprsIdentifier(XprsPacket.parse(w)!);
  XprsPacket answer(String code) => XprsPacket.parse(
      't:result f:X3AB3D d:X1ME77 ts:2026-09-10_12:00:05 r:${idOf(wire)} code:$code')!;

  test('only a command to one station is the courier\'s', () {
    expect(c.send('t:message f:X1ME77 d:X3AB3D ts:2026-09-10_12:00:00 m:hi'), isFalse);
    expect(c.send('t:command f:X1ME77 ts:2026-09-10_12:00:00 cmd:zdiag'), isFalse);
    expect(aired, isEmpty);
  });

  test('aired once on the chosen path, then the signed bytes on every path', () {
    expect(c.send(wire), isTrue);
    expect(aired, [(wire, false)]);
    now += 29000;
    c.tick();
    expect(aired.length, 1, reason: 'not before its time');
    now += 2000;
    c.tick();
    expect(aired.length, 2);
    expect(aired.last, (signed, true),
        reason: 'the same identifier, no second signature, fanned out');
  });

  test('a 202 keeps it in flight, a final code ends it', () {
    c.send(wire);
    c.onResult(answer('202'));
    expect(c.pending, 1, reason: 'the follow-up may be lost; a repeat asks for it');
    c.onResult(answer('200'));
    expect(c.pending, 0);
    expect(withdrawn, ['command:${idOf(wire)}'],
        reason: 'the answered copy leaves the advert rotation');
    now += 400000;
    c.tick();
    expect(reported, isEmpty);
  });

  test('silence for the whole window is reported, and so is a 202 with nothing after', () {
    c.send(wire);
    now += 300000;
    c.tick();
    expect(reported, [(idOf(wire), 'unanswered')]);
    expect(c.pending, 0);
    expect(aired.length, 1, reason: 'past the window nothing is aired again');

    reported.clear();
    c.send(wire);
    c.onResult(answer('202'));
    now += 300000;
    c.tick();
    expect(reported, [(idOf(wire), 'unfinished')]);
  });

  test('the schedule is four re-airs, not a clock', () {
    c.send(wire);
    for (var s = 0; s < 300; s += 5) {
      now += 5000;
      c.tick();
    }
    expect(aired.length, 1 + XprsCommandCourier.schedule.length);
  });
}
