/// A serial port, the little of one a ROM loader needs.
///
/// Two backends stand behind this: termios over dart:ffi on Linux
/// (serial_linux.dart) and a CDC-ACM bridge in Kotlin on Android
/// (serial_android.dart). The loader (esp_rom_loader.dart) is written against
/// this interface alone, so it runs on whichever isolate the port lives on:
/// the Linux port blocks in `poll`, so it lives on a worker isolate; the
/// Android port is a MethodChannel, so it lives on the main isolate and every
/// read is an await.
library;

import 'dart:typed_data';

/// One USB serial device the host can see. [id] is what the platform names
/// it by (`/dev/ttyACM1`, or Android's `/dev/bus/usb/001/004`) and is what a
/// wapp hands back to name a target.
class SerialDevice {
  final String id;
  final String port;
  final String product;
  final String manufacturer;
  final String serial;
  final int vid;
  final int pid;

  /// Android asks the person once per device; Linux has file permissions.
  final bool permitted;

  const SerialDevice({
    required this.id,
    required this.port,
    this.product = '',
    this.manufacturer = '',
    this.serial = '',
    this.vid = 0,
    this.pid = 0,
    this.permitted = true,
  });

  /// Espressif's own USB-serial-JTAG (S2, S3, C3, C6): a CDC device the chip
  /// itself is, with no UART bridge in between. Baud is meaningless on it and
  /// the reset sequence differs (esptool's USBJTAGSerialReset).
  bool get isNativeUsb => vid == 0x303A;

  Map<String, Object> toJson() => {
        'id': id,
        'port': port,
        'product': product,
        'manufacturer': manufacturer,
        'serial': serial,
        'vid': vid,
        'pid': pid,
        'permitted': permitted,
        'nativeUsb': isNativeUsb,
      };

  static SerialDevice fromJson(Map<String, dynamic> m) => SerialDevice(
        id: m['id'] as String? ?? '',
        port: m['port'] as String? ?? '',
        product: m['product'] as String? ?? '',
        manufacturer: m['manufacturer'] as String? ?? '',
        serial: m['serial'] as String? ?? '',
        vid: (m['vid'] as num?)?.toInt() ?? 0,
        pid: (m['pid'] as num?)?.toInt() ?? 0,
        permitted: m['permitted'] as bool? ?? true,
      );
}

class SerialException implements Exception {
  final String message;
  const SerialException(this.message);
  @override
  String toString() => message;
}

abstract class SerialPort {
  /// Open at [baud]; throws [SerialException] when it cannot.
  Future<void> open(int baud);

  /// Up to [max] bytes, or empty when nothing arrived within [timeoutMs].
  Future<Uint8List> read(int max, int timeoutMs);

  /// Write every byte; throws when the port is gone.
  Future<void> write(Uint8List data);

  Future<void> setDtr(bool on);
  Future<void> setRts(bool on);

  /// Change the line rate. On a native USB CDC this is accepted and ignored.
  Future<void> setBaud(int baud);

  /// Drop whatever is waiting to be read.
  Future<void> flushInput();

  Future<void> close();

  bool get isOpen;
}
