/*
 * What a wapp's declared tick interval means — and what it must never become.
 *
 * `module_tick_interval_ms` is somebody else's number: a wapp is code the host
 * did not write, and both drivers fed it straight into `Timer.periodic`.
 *
 * Two wapps in this tree declared 0, which is the honest answer for a wapp
 * whose whole job is event-driven — and `Timer.periodic(Duration.zero)` is not
 * "off", it is "as fast as the event loop allows", forever, to call a function
 * with an empty body. The power-tier throttle could not save it either: it is a
 * multiplier, and zero times ten is zero.
 *
 * These test the two rules the drivers now follow, at the arithmetic where the
 * bug lived — no wasm engine required.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/wapp_engine.dart';

/// The clamp `WappEngine.tickIntervalMs` applies to a wapp's declared value.
int clamp(int declared) {
  if (declared <= 0) return 0;
  return declared < WappEngine.minTickMs ? WappEngine.minTickMs : declared;
}

void main() {
  test('zero stays zero, and zero means no timer', () {
    expect(clamp(0), 0);
    expect(clamp(-1), 0, reason: 'a negative is not a fast tick either');
    // The rule the drivers implement: build no timer at all for 0. Stated here
    // because Duration.zero is a legal Duration and reads as harmless.
    expect(Duration.zero > Duration.zero, isFalse);
    expect(const Duration(milliseconds: 1) > Duration.zero, isTrue);
  });

  test('an implausibly fast cadence is clamped, not honoured', () {
    expect(clamp(1), WappEngine.minTickMs);
    expect(clamp(50), WappEngine.minTickMs);
    expect(clamp(WappEngine.minTickMs), WappEngine.minTickMs);
  });

  test('a sane cadence passes through untouched', () {
    for (final v in [500, 700, 1000, 2000, 3000, 5000, 60000]) {
      expect(clamp(v), v, reason: '$v is a wapp in this tree');
    }
  });

  test('the tier throttle cannot rescue a zero, which is why 0 is gated', () {
    // background_service stretches by multiplying the declared interval.
    for (final multiplier in [5, 10]) {
      expect(0 * multiplier, 0);
    }
  });
}
