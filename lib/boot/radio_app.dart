/*
 * The app's BLE5 radio behind the core's AdvertRadio: the advert bus
 * (Ble5Bus, a platform channel) and BleService's size-routed queue.
 */
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart' show Ble5Frame;
import 'package:xprs_core/src/platform/advert_radio.dart';
import 'package:xprs_core/src/platform/core_host.dart';

import '../connections/bluetooth/ble5_bus.dart';
import '../connections/bluetooth/ble_service.dart';

class AppAdvertRadio implements AdvertRadio {
  const AppAdvertRadio();
  @override
  int get maxPayload => Ble5Bus.instance.maxPayload;
  @override
  // Bluetooth not granted reads as "no radio here": every core user (the
  // publisher's status adverts, the mesh, custody re-airs) already copes with
  // a phone that has none, and nothing then fails against the OS on a tick.
  Future<bool> supported() async =>
      CoreHost.radioAllowed() && await Ble5Bus.instance.supported();
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
  Future<void> startScan() async {
    // Not granted: the scan would only be refused (and logged) on every tick.
    if (!CoreHost.radioAllowed()) return;
    await Ble5Bus.instance.startScan();
  }
  @override
  Future<bool> advertiseFrame(String key, int subtype, Uint8List data,
      {Duration ttl = const Duration(seconds: 35), bool prio = false}) async {
    if (!CoreHost.radioAllowed()) return false;
    return Ble5Bus.instance
        .advertiseFrame(key, subtype, data, ttl: ttl, prio: prio);
  }
  @override
  void enqueueAdvert(Object owner, Uint8List payload,
          {required int subtype, Duration ttl = const Duration(seconds: 10)}) =>
      BleService.instance.enqueueAdvert(owner, payload, subtype: subtype, ttl: ttl);
}
