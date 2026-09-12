/// Android serial through the USB host API, behind the
/// `com.xprs.app/usb_serial` channel (android/.../UsbSerial.kt).
///
/// The Kotlin side does the bulk transfers on its own executor and answers
/// each call on the main thread, so every read here is one await and the UI
/// isolate never blocks. A 1 KB flash block is one write and one read: about
/// 1,500 round trips for a 1.5 MB image, a few milliseconds each.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'serial_port.dart';

class AndroidUsbSerial {
  static const channel = MethodChannel('com.xprs.app/usb_serial');

  /// Called when a device was plugged in or pulled, or a permission answered.
  static void Function()? onDevicesChanged;

  static bool _handlerSet = false;

  static void _ensureHandler() {
    if (_handlerSet) return;
    _handlerSet = true;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'onDevicesChanged' ||
          call.method == 'onPermissionChanged') {
        onDevicesChanged?.call();
      }
      return null;
    });
  }

  static Future<List<SerialDevice>> listDevices() async {
    _ensureHandler();
    try {
      final raw = await channel.invokeMethod<List<Object?>>('listDevices');
      return [
        for (final e in raw ?? const [])
          if (e is Map)
            SerialDevice(
              id: e['deviceName'] as String? ?? '',
              port: e['deviceName'] as String? ?? '',
              product: e['productName'] as String? ?? '',
              manufacturer: e['manufacturerName'] as String? ?? '',
              serial: e['serialNumber'] as String? ?? '',
              vid: (e['vendorId'] as num?)?.toInt() ?? 0,
              pid: (e['productId'] as num?)?.toInt() ?? 0,
              permitted: e['hasPermission'] as bool? ?? false,
            ),
      ];
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  /// Ask the person for the device; true when granted (or already held).
  static Future<bool> requestPermission(String id) async {
    _ensureHandler();
    try {
      return await channel.invokeMethod<bool>(
              'requestPermission', {'deviceName': id}) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

class AndroidSerialPort implements SerialPort {
  final String id;
  bool _open = false;

  AndroidSerialPort(this.id);

  MethodChannel get _ch => AndroidUsbSerial.channel;

  @override
  bool get isOpen => _open;

  @override
  Future<void> open(int baud) async {
    try {
      final ok = await _ch
          .invokeMethod<bool>('open', {'deviceName': id, 'baudRate': baud});
      if (ok != true) throw SerialException('cannot open $id');
      _open = true;
    } on PlatformException catch (e) {
      throw SerialException(e.message ?? e.code);
    }
  }

  @override
  Future<Uint8List> read(int max, int timeoutMs) async {
    if (!_open) throw const SerialException('port closed');
    try {
      final r = await _ch.invokeMethod<Uint8List>(
          'read', {'deviceName': id, 'maxBytes': max, 'timeoutMs': timeoutMs});
      return r ?? Uint8List(0);
    } on PlatformException catch (e) {
      throw SerialException(e.message ?? e.code);
    }
  }

  @override
  Future<void> write(Uint8List data) async {
    if (!_open) throw const SerialException('port closed');
    try {
      final n = await _ch
          .invokeMethod<int>('write', {'deviceName': id, 'data': data});
      if (n != data.length) throw const SerialException('short write');
    } on PlatformException catch (e) {
      throw SerialException(e.message ?? e.code);
    }
  }

  @override
  Future<void> setDtr(bool on) async {
    if (!_open) return;
    try {
      await _ch.invokeMethod<bool>('setDTR', {'deviceName': id, 'value': on});
    } on PlatformException {
      // A bridge without a DTR line: the reset sequence is best effort.
    }
  }

  @override
  Future<void> setRts(bool on) async {
    if (!_open) return;
    try {
      await _ch.invokeMethod<bool>('setRTS', {'deviceName': id, 'value': on});
    } on PlatformException {
      // As above.
    }
  }

  @override
  Future<void> setBaud(int baud) async {
    if (!_open) return;
    try {
      await _ch.invokeMethod<bool>(
          'setBaudRate', {'deviceName': id, 'baudRate': baud});
    } on PlatformException {
      // A native USB CDC ignores it anyway.
    }
  }

  @override
  Future<void> flushInput() async {
    if (!_open) return;
    try {
      await _ch.invokeMethod<bool>('flush', {'deviceName': id});
    } on PlatformException {
      // Nothing to drop.
    }
  }

  @override
  Future<void> close() async {
    if (!_open) return;
    _open = false;
    try {
      await _ch.invokeMethod<bool>('close', {'deviceName': id});
    } on PlatformException {
      // Already gone.
    }
  }
}
