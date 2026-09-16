// Asking the local network who is there (XprsLan.sweep).
//
// What has to hold: the sweep asks the building and nothing else, never
// itself, never a container bridge, never the internet; and a sweep cannot be
// fired faster than the bearer allows, or while the bearer is down.
import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/xprs/xprs_lan.dart';

void main() {
  group('where a sweep asks', () {
    test('every host of the /24 around our private address, not us', () {
      final t = xprsLanSweepTargets([(iface: 'wlan0', addr: '192.168.178.23')]);
      expect(t, hasLength(253));
      expect(t.first, '192.168.178.1');
      expect(t.last, '192.168.178.254');
      expect(t, isNot(contains('192.168.178.23')));
      expect(t, isNot(contains('192.168.178.0')));
      expect(t, isNot(contains('192.168.178.255')));
    });

    test('private and link-local space only: a public address is the internet',
        () {
      expect(xprsLanSweepTargets([(iface: 'eth0', addr: '81.20.1.7')]), isEmpty);
      expect(xprsLanSweepTargets([(iface: 'eth0', addr: '10.0.3.9')]),
          hasLength(253));
      expect(xprsLanSweepTargets([(iface: 'eth0', addr: '172.20.10.2')]),
          hasLength(253));
      expect(xprsLanSweepTargets([(iface: 'eth0', addr: '172.32.0.2')]),
          isEmpty, reason: '172.32 is outside RFC 1918');
      expect(xprsLanSweepTargets([(iface: 'eth0', addr: '169.254.7.7')]),
          hasLength(253));
    });

    test('nothing an operator put in a room lives behind a container bridge',
        () {
      final t = xprsLanSweepTargets([
        (iface: 'docker0', addr: '172.17.0.1'),
        (iface: 'br-1a2b', addr: '172.18.0.1'),
        (iface: 'virbr0', addr: '192.168.122.1'),
        (iface: 'wlp2s0', addr: '192.168.1.40'),
      ]);
      expect(t.every((ip) => ip.startsWith('192.168.1.')), isTrue);
    });

    test('two addresses on one subnet sweep it once, and the subnets are capped',
        () {
      expect(
          xprsLanSweepTargets([
            (iface: 'wlan0', addr: '192.168.1.40'),
            (iface: 'eth0', addr: '192.168.1.41'),
          ]),
          hasLength(252));
      final many = [
        for (var i = 0; i < 10; i++) (iface: 'eth$i', addr: '10.0.$i.5')
      ];
      expect(xprsLanSweepTargets(many, maxSubnets: 4), hasLength(4 * 253));
    });
  });

  test('a bearer that is down asks nobody, and says so', () {
    final lan = XprsLan.instance;
    final refused = lan.sweepRefused;
    expect(lan.up, isFalse);
    expect(lan.sweep(), isFalse);
    expect(lan.sweepRefused, refused + 1);
    expect(lan.statusJson()['sweep']['sweeps'], 0);
  });
}
