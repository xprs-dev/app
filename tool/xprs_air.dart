// xprs_air — air an XPRS wire from this Linux box, so the phone's BLE5 receive
// path can be exercised without an ESP32 on the bench.
//
// Company 0xFFFF, marker 0x3E, subtype 0x58 (docs/ble5.md section 2) — the same
// framing a station uses, so the phone cannot tell this apart from one.
//
//   dart run tool/xprs_air.dart "t:observation f:X9TEST link:ble peers:1"
//
// Re-airs every 10 s until interrupted: a frame transmitted once may not be
// observed (docs/ble5.md section 5).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluez/bluez.dart';
import 'package:dbus/dbus.dart';

const int _company = 0xFFFF;
const int _marker = 0x3E;
const int _subtype = 0x58; // Ble5Subtype.xprs

Future<void> main(List<String> args) async {
  final wire = args.isNotEmpty
      ? args.join(' ')
      : 't:observation f:X9TEST link:ble peers:1 mail:0';

  final client = BlueZClient();
  await client.connect();
  if (client.adapters.isEmpty) {
    print('no bluetooth adapter');
    await client.close();
    return;
  }
  final adapter = client.adapters.first;
  if (!adapter.powered) await adapter.setPowered(true);

  final body = utf8.encode(wire);
  final payload = Uint8List(2 + body.length)
    ..[0] = _marker
    ..[1] = _subtype
    ..setRange(2, 2 + body.length, body);

  BlueZAdvertisement? advert;
  var tick = 0;
  Future<void> air() async {
    try {
      if (advert != null) {
        await adapter.advertisingManager.unregisterAdvertisement(advert!);
        advert = null;
      }
      advert = await adapter.advertisingManager.registerAdvertisement(
        type: BlueZAdvertisementType.peripheral,
        manufacturerData: {
          BlueZManufacturerId(_company): DBusArray.byte(payload),
        },
      );
      print('XPRS_TX #${++tick} ${payload.length}B  <- $wire');
    } catch (e) {
      print('XPRS_TX failed: $e');
    }
  }

  await air();
  await for (final _ in Stream.periodic(const Duration(seconds: 10))) {
    await air();
  }
}
