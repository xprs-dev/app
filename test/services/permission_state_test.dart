import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/permission_state.dart';

void main() {
  final caps = PermissionState.capabilities;

  test('everything granted: every capability on', () {
    for (final sdk in [0, 29, 30, 31, 33, 35]) {
      final c = caps(<String>{}, sdk);
      expect(c.bluetooth, isTrue, reason: 'sdk $sdk');
      expect(c.nearbyWifi, isTrue, reason: 'sdk $sdk');
    }
  });

  test('Bluetooth refused turns the radio off on every version', () {
    for (final sdk in [0, 29, 31, 34]) {
      expect(caps({'bluetooth'}, sdk).bluetooth, isFalse, reason: 'sdk $sdk');
    }
  });

  test('Location refused costs Bluetooth only on Android 11 and older', () {
    expect(caps({'location'}, 30).bluetooth, isFalse);
    expect(caps({'location'}, 29).bluetooth, isFalse);
    expect(caps({'location'}, 31).bluetooth, isTrue);
    expect(caps({'location'}, 0).bluetooth, isTrue); // unknown: modern rules
  });

  test('WiFi Direct follows nearby_wifi from 33, location before', () {
    expect(caps({'nearby_wifi'}, 33).nearbyWifi, isFalse);
    expect(caps({'location'}, 33).nearbyWifi, isTrue);
    expect(caps({'location'}, 31).nearbyWifi, isFalse);
    expect(caps({'nearby_wifi'}, 31).nearbyWifi, isTrue);
  });

  test('other refusals leave the radios alone', () {
    final c = caps({'notifications', 'storage', 'battery'}, 34);
    expect(c.bluetooth, isTrue);
    expect(c.nearbyWifi, isTrue);
  });
}
