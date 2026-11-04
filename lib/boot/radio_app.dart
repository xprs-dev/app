/*
 * The app's BLE5 radio behind the core's AdvertRadio: the advert bus
 * (Ble5Bus, a platform channel) and BleService's size-routed queue.
 */
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart' show Ble5Frame;
import 'package:xprs_core/src/platform/advert_radio.dart';

import '../connections/bluetooth/ble5_bus.dart';
import '../connections/bluetooth/ble_service.dart';

class AppAdvertRadio implements AdvertRadio {
  const AppAdvertRadio();
  @override
  int get maxPayload => Ble5Bus.instance.maxPayload;
  @override
  Future<bool> supported() => Ble5Bus.instance.supported();
  @override
  Future<bool> adapterOn() => Ble5Bus.instance.adapterOn();
  @override
  bool get poweredOn => BleService.instance.poweredOn;
  @override
  Future<void> removeFrame(String key) => Ble5Bus.instance.removeFrame(key);
  @override
  void onFrame(int subtype, void Function(Ble5Frame) handler) =>
      Ble5Bus.instance.onFrame(subtype, handler);
  @override
  Future<void> startScan() => Ble5Bus.instance.startScan();
  @override
  Future<bool> advertiseFrame(String key, int subtype, Uint8List data,
          {Duration ttl = const Duration(seconds: 35), bool prio = false}) =>
      Ble5Bus.instance.advertiseFrame(key, subtype, data, ttl: ttl, prio: prio);
  @override
  void enqueueAdvert(Object owner, Uint8List payload,
          {required int subtype, Duration ttl = const Duration(seconds: 10)}) =>
      BleService.instance.enqueueAdvert(owner, payload, subtype: subtype, ttl: ttl);
}
