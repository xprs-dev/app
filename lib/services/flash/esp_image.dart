/// What an ESP-IDF image and a partition table say about themselves, read
/// off bytes. Pure Dart, no I/O: tested from fixtures, used by the loader to
/// refuse a wrong image before a sector is touched and to find the NVS
/// partition it must never write except on an explicit wipe.
library;

import 'dart:typed_data';

/// The chip families this app flashes, named as boards.json names them.
class EspFamily {
  static const esp32 = 'esp32';
  static const esp32s2 = 'esp32s2';
  static const esp32s3 = 'esp32s3';
  static const esp32c3 = 'esp32c3';
  static const esp32c6 = 'esp32c6';
  static const esp32h2 = 'esp32h2';
  static const esp32c2 = 'esp32c2';

  /// READ_REG 0x40001000, the ROM's chip detect magic.
  static String? fromMagic(int magic) => switch (magic) {
        0x00F01D83 => esp32,
        0x000007C6 => esp32s2,
        0x00000009 => esp32s3,
        0x6921506F || 0x1B31506F || 0x4881606F || 0x4361606F => esp32c3,
        0x2CE0806F => esp32c6,
        0xD7B73E80 => esp32h2,
        0x6F51306F || 0x7C41A06F => esp32c2,
        _ => null,
      };

  /// The chip id at byte 12 of an ESP-IDF image header.
  static String? fromImageChipId(int id) => switch (id) {
        0x0000 => esp32,
        0x0002 => esp32s2,
        0x0005 => esp32c3,
        0x0009 => esp32s3,
        0x000C => esp32c2,
        0x000D => esp32c6,
        0x0010 => esp32h2,
        _ => null,
      };

  /// ESP Web Tools' `chipFamily` spelling, as the manifests carry it.
  static String? fromWebTools(String s) {
    final t = s.toLowerCase().replaceAll('-', '');
    return const {
      'esp32': esp32,
      'esp32s2': esp32s2,
      'esp32s3': esp32s3,
      'esp32c3': esp32c3,
      'esp32c6': esp32c6,
      'esp32h2': esp32h2,
      'esp32c2': esp32c2,
    }[t];
  }

  static String label(String f) => switch (f) {
        esp32 => 'ESP32',
        esp32s2 => 'ESP32-S2',
        esp32s3 => 'ESP32-S3',
        esp32c3 => 'ESP32-C3',
        esp32c6 => 'ESP32-C6',
        esp32h2 => 'ESP32-H2',
        esp32c2 => 'ESP32-C2',
        _ => f,
      };
}

/// The chip an ESP-IDF image (0xE9 magic) was built for, or null when the
/// bytes are not such an image.
String? espImageFamily(Uint8List b) {
  if (b.length < 24 || b[0] != 0xE9) return null;
  return EspFamily.fromImageChipId(b[12] | (b[13] << 8));
}

/// `esp_app_desc_t`, the block every ESP-IDF app carries at +0x20: what
/// project it is and which version. What a probe reads off a board to name
/// the firmware already there.
class EspAppDesc {
  final String project;
  final String version;
  const EspAppDesc(this.project, this.version);

  static const magic = 0xABCD5432;

  /// [b] starts at the app's flash offset (the 0xE9 header) or at +0x20
  /// (the descriptor itself); both are recognised.
  static EspAppDesc? parse(Uint8List b) {
    for (final start in [0x20, 0]) {
      if (b.length < start + 80) continue;
      final d = ByteData.sublistView(b, start);
      if (d.getUint32(0, Endian.little) != magic) continue;
      return EspAppDesc(
          _cstr(b, start + 48, 32), _cstr(b, start + 16, 32));
    }
    return null;
  }

  static String _cstr(Uint8List b, int off, int len) {
    final end = b.indexOf(0, off);
    final stop = end < 0 || end > off + len ? off + len : end;
    return String.fromCharCodes(b.sublist(off, stop)).trim();
  }
}

class EspPartition {
  final int type;
  final int subtype;
  final int offset;
  final int size;
  final String label;
  const EspPartition(this.type, this.subtype, this.offset, this.size, this.label);

  bool get isNvs => type == 1 && subtype == 2;
  bool get isOtaData => type == 1 && subtype == 0;
}

/// The entries of a partition table image (what sits at 0x8000): 32-byte
/// rows under magic 0x50AA, ended by an MD5 row (0xEBEB) or 0xFFFF.
List<EspPartition> espParsePartitions(Uint8List b) {
  final out = <EspPartition>[];
  for (var off = 0; off + 32 <= b.length; off += 32) {
    final d = ByteData.sublistView(b, off, off + 32);
    final magic = d.getUint16(0, Endian.little);
    if (magic != 0x50AA) break;
    out.add(EspPartition(
      b[off + 2],
      b[off + 3],
      d.getUint32(4, Endian.little),
      d.getUint32(8, Endian.little),
      EspAppDesc._cstr(b, off + 12, 16),
    ));
  }
  return out;
}
