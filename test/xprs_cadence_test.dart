/// The poll interval follows the room, inside the budgets the peer sets.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/xprs/xprs_cadence.dart';

Duration _next(
  Duration current,
  XprsAnswer answer, {
  XprsPeerClass peer = XprsPeerClass.fast,
  bool visible = true,
  Duration silentFor = Duration.zero,
}) =>
    XprsCadence.next(
      current: current,
      answer: answer,
      peer: peer,
      visible: visible,
      silentFor: silentFor,
    );

void main() {
  test('a talking archiver is asked sooner, down to the fast floor', () {
    var d = const Duration(minutes: 10);
    for (var i = 0; i < 10; i++) {
      d = _next(d, XprsAnswer.news);
    }
    expect(d, XprsCadence.fastFloor,
        reason: 'a busy room converges on the floor and stops there');
  });

  test('a quiet archiver is asked less often, up to the ceiling', () {
    var d = XprsCadence.fastFloor;
    for (var i = 0; i < 12; i++) {
      d = _next(d, XprsAnswer.quiet);
    }
    expect(d, XprsCadence.ceilingFresh);
  });

  test('the ceiling steps at a week and at three months', () {
    expect(XprsCadence.ceilingFor(const Duration(days: 1)),
        XprsCadence.ceilingFresh);
    expect(XprsCadence.ceilingFor(const Duration(days: 8)),
        XprsCadence.ceilingWeek);
    expect(XprsCadence.ceilingFor(const Duration(days: 120)),
        XprsCadence.ceilingQuarter);
  });

  test('an archiver silent for three months settles at six hours', () {
    var d = XprsCadence.fastFloor;
    for (var i = 0; i < 20; i++) {
      d = _next(d, XprsAnswer.quiet, silentFor: const Duration(days: 100));
    }
    expect(d, XprsCadence.ceilingQuarter);
  });

  test('an ordinary archiver is never asked faster than section 36.10.1', () {
    var d = const Duration(minutes: 10);
    for (var i = 0; i < 10; i++) {
      d = _next(d, XprsAnswer.news, peer: XprsPeerClass.ordinary);
    }
    expect(d, XprsCadence.ordinaryFloor,
        reason: 'six replays an hour is the budget, and ten minutes is it');
  });

  test('nobody looking means nobody is polled fast', () {
    var d = const Duration(minutes: 10);
    for (var i = 0; i < 10; i++) {
      d = _next(d, XprsAnswer.news, visible: false);
    }
    expect(d, XprsCadence.hiddenFloor);
  });

  test('a refusal always slows us down, even from the floor', () {
    final backed = _next(XprsCadence.fastFloor, XprsAnswer.refused);

    expect(backed, greaterThan(XprsCadence.fastFloor),
        reason: '429 is the peer saying our cadence is wrong; obeying it is '
            'the whole point');
    expect(backed, greaterThanOrEqualTo(XprsCadence.refusedMin));
  });

  test('repeated refusals climb to the ceiling and stop', () {
    var d = XprsCadence.fastFloor;
    for (var i = 0; i < 10; i++) {
      d = _next(d, XprsAnswer.refused);
    }
    expect(d, XprsCadence.ceilingFresh);
  });

  test('a room that wakes up recovers quickly', () {
    var d = XprsCadence.ceilingFresh; // ten minutes, gone quiet
    d = _next(d, XprsAnswer.news);
    d = _next(d, XprsAnswer.news);
    d = _next(d, XprsAnswer.news);

    expect(d, lessThanOrEqualTo(const Duration(minutes: 2)),
        reason: 'three answers is a conversation, not a coincidence');
  });

  test('a fresh archiver starts polite', () {
    expect(XprsCadence.initial, XprsCadence.ordinaryFloor);
  });

  test('jitter stays within a tenth and never goes sub-second', () {
    const base = Duration(minutes: 10);
    for (final r in [0.0, 0.25, 0.5, 0.75, 1.0]) {
      final j = XprsCadence.jitter(base, r);
      expect((j - base).abs(), lessThanOrEqualTo(base * 0.1));
    }
    expect(XprsCadence.jitter(const Duration(milliseconds: 200), 0.0).inMilliseconds,
        greaterThanOrEqualTo(1000));
  });
}
