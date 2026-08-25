// What a `via` label means to a person. rnsIfaceKind answers "is this local",
// which is one bit too coarse for a chip in front of a reader: it is why a
// message off the board on the bench used to say it came from Reticulum.
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/reticulum/rns_iface_kind.dart';

void main() {
  test('a local interface names its own bearer, not the lane', () {
    expect(rnsIfaceBearer('ble'), 'ble');
    expect(rnsIfaceBearer('ble5'), 'ble');
    expect(rnsIfaceBearer('lan'), 'lan');
    expect(rnsIfaceBearer('espnow'), 'espnow');
    expect(rnsIfaceBearer('lora0'), 'lora');
    expect(rnsIfaceBearer('wifi'), 'wifi');
    expect(rnsIfaceBearer('vhf'), 'vhf');
    expect(rnsIfaceBearer('kiss'), 'radio');
  });

  test('two devices on one LAN over TCP are on the LAN, not the internet', () {
    expect(rnsIfaceBearer('tcps#3:192.168.1.42:51234'), 'lan');
    expect(rnsIfaceBearer('tcp:10.0.0.7:4965'), 'lan');
    expect(rnsIfaceBearer('wfd:192.168.49.1:4242'), 'lan');
  });

  test('only what genuinely crossed the internet is called rns', () {
    expect(rnsIfaceBearer('tcp:reticulum.example.org:4965'), 'rns');
    expect(rnsIfaceBearer('udp:203.0.113.9:4242'), 'rns');
    // No label at all: the honest answer is the lane it was handed over on.
    expect(rnsIfaceBearer(''), 'rns');
    expect(rnsIfaceBearer('   '), 'rns');
  });
}
