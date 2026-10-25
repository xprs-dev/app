/// The two system switches outside the app that silence the Bluetooth mesh,
/// and the one rule for telling the person about them: once, when a switch
/// goes off, and never again until it has been seen on.
///
/// Android hands the app zero scan results while Location Services are off,
/// whatever permissions it holds, and answers "no" to every LE capability
/// question while Bluetooth is off. Both leave a phone that looks healthy and
/// hears and says nothing (docs/ble5.md section 5). The probes are platform
/// calls, so the service asks on a paced heartbeat and hands the answers here;
/// this class holds no platform code, so the rule is testable without a phone.
class RadioEnvironment {
  bool? _location;
  bool? _bluetooth;

  /// What the last probe said; null until a probe has answered.
  bool? get locationOn => _location;
  bool? get bluetoothOn => _bluetooth;

  /// Record one round of answers (null = the probe could not tell, ignored)
  /// and return the switches that went OFF in this round. A switch found off
  /// on the very first answer counts: that is the fresh-install case.
  List<String> note({bool? location, bool? bluetooth}) {
    final off = <String>[];
    if (location != null && location != _location) {
      _location = location;
      if (!location) off.add('location');
    }
    if (bluetooth != null && bluetooth != _bluetooth) {
      _bluetooth = bluetooth;
      if (!bluetooth) off.add('bluetooth');
    }
    return off;
  }
}
