// The funnel delivers, it does not only file.
//
// XprsIngest.heard is the one surface every bearer reaches — BLE 0x58, BLE
// 0x41, LAN UDP, TCP. It always knew when a packet was addressed to us, and
// used that only to decide whether to archive it. The single route to the
// inbox ran through the BLE 0x41 custody tap, so a message a station replayed
// on 0x58 — which is what every cmd:history replay is — was archived and never
// seen again. These tests pin the delivery hook to the funnel, and pin it
// bearer-agnostically: whatever carried the packet, it is delivered.
import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_monitor.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';

const _self = 'X1A67X';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<({String from, String bearer})> delivered;

  setUp(() {
    delivered = [];
    XprsMonitor.instance.debugReset();
    XprsIngest.onDeliver =
        (p, bearer) => delivered.add((from: p['f'] ?? '', bearer: bearer));
  });

  tearDown(() => XprsIngest.onDeliver = null);

  void heard(String wire, String bearer) => XprsIngest.heard(
      XprsPacket.parse(wire)!,
      bearer: bearer,
      selfCallsign: _self);

  test('a message addressed to us is delivered, on every bearer', () {
    // The replay lane that was dead: a station re-airing our mail on 0x58.
    heard('t:message f:X3WWAJ d:$_self ts:2026-08-21_10:00:00 m:hello', 'ble');
    // And the same packet over the wire, which had no delivery path either.
    heard('t:message f:X3LTSH d:$_self ts:2026-08-21_10:00:01 m:hello', 'lan');

    expect(delivered.map((d) => d.from), ['X3WWAJ', 'X3LTSH']);
    expect(delivered.map((d) => d.bearer), ['ble', 'lan'],
        reason: 'delivery must not be a property of which radio carried it');
  });

  test('a message addressed to another station is not delivered', () {
    heard('t:message f:X3WWAJ d:X9OTHER ts:2026-08-21_10:00:00 m:not yours',
        'ble');
    expect(delivered, isEmpty);
  });

  test('a broadcast message is not delivered as ours', () {
    // No d: at all — room traffic, which the chat wapp fills from the archive.
    heard('t:message f:X3WWAJ ts:2026-08-21_10:00:00 m:anyone there', 'ble');
    expect(delivered, isEmpty);
  });

  test('a device suffix on our own callsign still counts as ours', () {
    // Section 3.1: X1A67X-2 is another of OUR devices, and mail addressed to
    // the base callsign is ours.
    heard('t:message f:X3WWAJ d:$_self-2 ts:2026-08-21_10:00:00 m:hi', 'ble');
    expect(delivered, hasLength(1));
  });

  test('only a message is delivered, not a beacon that names us', () {
    heard('t:observation f:X3WWAJ d:$_self link:ble peers:1', 'ble');
    heard('t:result f:X3WWAJ d:$_self r:abc123 code:200', 'ble');
    expect(delivered, isEmpty,
        reason: 'the courier lane is for mail, and verification is not free');
  });

  test('our own echo is never delivered back to us', () {
    heard('t:message f:$_self d:$_self ts:2026-08-21_10:00:00 m:echo', 'ble');
    expect(delivered, isEmpty);
  });
}
