import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/connections/bluetooth/radio_environment.dart';

void main() {
  test('a switch found off is reported once per off episode', () {
    final env = RadioEnvironment();
    // Fresh install, Location already off: said at once.
    expect(env.note(location: false, bluetooth: true), ['location']);
    // Still off on the next heartbeat: silence, not a nag every 30 s.
    expect(env.note(location: false, bluetooth: true), isEmpty);
    // Back on: nothing to warn about.
    expect(env.note(location: true, bluetooth: true), isEmpty);
    expect(env.locationOn, isTrue);
    // Off again later: a new episode, said again.
    expect(env.note(location: false, bluetooth: true), ['location']);
  });

  test('an unanswered probe changes nothing', () {
    final env = RadioEnvironment();
    expect(env.note(location: null, bluetooth: null), isEmpty);
    expect(env.locationOn, isNull);
    expect(env.note(location: true, bluetooth: false), ['bluetooth']);
    // A timeout in the middle of an off episode is not "on".
    expect(env.note(location: null, bluetooth: null), isEmpty);
    expect(env.bluetoothOn, isFalse);
    expect(env.note(location: true, bluetooth: false), isEmpty);
  });

  test('both off at once are both named', () {
    expect(RadioEnvironment().note(location: false, bluetooth: false),
        ['location', 'bluetooth']);
  });
}
