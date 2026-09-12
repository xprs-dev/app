/*
 * The ROM loader against a scripted ROM, and the catalogue against
 * fixtures. No port, no network.
 *
 * What these hold the core to:
 *   - it speaks esptool's protocol: SLIP, the command shape, the extra word
 *     an S3 ROM wants in FLASH_BEGIN, SPI_SET_PARAMS with the size it read;
 *   - every part is verified by the ROM's MD5 and a mismatch is a failure,
 *     not a warning;
 *   - a lost frame is retried once and a second miss fails the write;
 *   - a cancel stops between blocks;
 *   - an image for another chip is refused before FLASH_BEGIN;
 *   - a wipe touches the partitions the table names and nothing else;
 *   - the catalogue picks the board whose own firmware is on the chip, and
 *     narrows by family and flash size when it is not.
 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/flash/esp_image.dart';
import 'package:xprs/services/flash/esp_rom_loader.dart';
import 'package:xprs/services/flash/flash_catalog.dart';
import 'package:xprs/services/flash/flash_service_io.dart';
import 'package:xprs/services/flash/serial/serial_port.dart';

/// A ROM on the other end of the wire: answers SYNC, registers, flash
/// commands, keeps the flash it was written.
class FakeRom implements SerialPort {
  final int magic;
  final int flashId;
  final Uint8List flash;
  final List<int> _rx = [];
  final List<int> _tx = [];
  final List<(int, Uint8List)> commands = [];
  bool opened = false;
  int baud = 0;
  int dtrChanges = 0;
  int syncsBeforeAnswer;
  int failDataBlocks = 0; // answer FLASH_DATA with status 1 this many times
  bool corruptMd5 = false;
  int beginOffset = -1;
  int beginSize = -1;
  int beginBlocks = -1;
  int beginLen = -1;
  int spiSetSize = -1;
  final regs = <int, int>{};

  FakeRom({this.magic = 0x9, this.flashId = 0x1840EF, int flashBytes = 0x30000,
      this.syncsBeforeAnswer = 0})
      : flash = Uint8List(flashBytes)..fillRange(0, flashBytes, 0xFF);

  @override
  bool get isOpen => opened;
  @override
  Future<void> open(int b) async {
    opened = true;
    baud = b;
  }

  @override
  Future<void> close() async => opened = false;
  @override
  Future<void> flushInput() async => _rx.clear();
  @override
  Future<Uint8List?> transact(Uint8List data, int timeoutMs) async => null;

  /// When set, the fake behaves like the Android bridge: a run of frames
  /// in one call, one answer each, in order.
  bool batched = false;
  int batches = 0;
  @override
  Future<List<Uint8List>?> transactMany(List<Uint8List> frames, int timeoutMs) async {
    if (!batched) return null;
    batches++;
    final out = <Uint8List>[];
    for (final f in frames) {
      _rx.clear();
      await write(f);
      out.add(Uint8List.fromList(_rx));
      _rx.clear();
    }
    return out;
  }
  @override
  Future<void> setBaud(int b) async => baud = b;
  @override
  Future<void> setDtr(bool on) async => dtrChanges++;
  @override
  Future<void> setRts(bool on) async {}

  @override
  Future<Uint8List> read(int max, int timeoutMs) async {
    if (_rx.isEmpty) return Uint8List(0);
    final n = _rx.length < max ? _rx.length : max;
    final out = Uint8List.fromList(_rx.sublist(0, n));
    _rx.removeRange(0, n);
    return out;
  }

  @override
  Future<void> write(Uint8List data) async {
    _tx.addAll(data);
    // Frame: END ... END
    while (true) {
      final s = _tx.indexOf(0xC0);
      if (s < 0) return;
      final e = _tx.indexOf(0xC0, s + 1);
      if (e < 0) return;
      final raw = _tx.sublist(s + 1, e);
      _tx.removeRange(0, e + 1);
      if (raw.isEmpty) continue;
      final f = <int>[];
      for (var i = 0; i < raw.length; i++) {
        if (raw[i] == 0xDB) {
          i++;
          f.add(raw[i] == 0xDC ? 0xC0 : 0xDB);
        } else {
          f.add(raw[i]);
        }
      }
      _handle(Uint8List.fromList(f));
    }
  }

  void _reply(int op, int value, List<int> data, {int status = 0, int code = 0}) {
    final body = [...data, status, code, 0, 0];
    final h = ByteData(8)
      ..setUint8(0, 1)
      ..setUint8(1, op)
      ..setUint16(2, body.length, Endian.little)
      ..setUint32(4, value, Endian.little);
    _rx.addAll(EspRomLoader.slipEncode([...h.buffer.asUint8List(), ...body]));
  }

  void _handle(Uint8List f) {
    final op = f[1];
    final d = ByteData.sublistView(f, 8);
    final data = Uint8List.sublistView(f, 8);
    commands.add((op, data));
    switch (op) {
      case 0x08: // SYNC
        if (syncsBeforeAnswer > 0) {
          syncsBeforeAnswer--;
          return;
        }
        for (var i = 0; i < 8; i++) {
          _reply(op, 0, []);
        }
      case 0x0A: // READ_REG
        final addr = d.getUint32(0, Endian.little);
        int v;
        if (addr == 0x40001000) {
          v = magic;
        } else if (addr == 0x60002000 || addr == 0x3FF42000) {
          v = 0; // SPI busy bit clear
        } else if (addr == 0x60002058 || addr == 0x3FF42080) {
          v = flashId;
        } else {
          v = regs[addr] ?? 0;
        }
        _reply(op, v, []);
      case 0x09: // WRITE_REG
        regs[d.getUint32(0, Endian.little)] = d.getUint32(4, Endian.little);
        _reply(op, 0, []);
      case 0x0D: // SPI_ATTACH
        _reply(op, 0, []);
      case 0x0B: // SPI_SET_PARAMS
        spiSetSize = d.getUint32(4, Endian.little);
        _reply(op, 0, []);
      case 0x0F: // CHANGE_BAUDRATE
        _reply(op, 0, []);
      case 0x02: // FLASH_BEGIN
        beginSize = d.getUint32(0, Endian.little);
        beginBlocks = d.getUint32(4, Endian.little);
        beginOffset = d.getUint32(12, Endian.little);
        beginLen = data.length;
        _reply(op, 0, []);
      case 0x03: // FLASH_DATA
        if (failDataBlocks > 0) {
          failDataBlocks--;
          _reply(op, 0, [], status: 1, code: 6);
          return;
        }
        final len = d.getUint32(0, Endian.little);
        final seq = d.getUint32(4, Endian.little);
        final block = data.sublist(16, 16 + len);
        final chk = EspRomLoader.checksum(block);
        final want = ByteData.sublistView(f, 4).getUint32(0, Endian.little);
        if (chk != want) {
          _reply(op, 0, [], status: 1, code: 9);
          return;
        }
        final at = beginOffset + seq * 0x400;
        final n = (beginSize - seq * 0x400).clamp(0, len);
        if (at + n <= flash.length) flash.setRange(at, at + n, block);
        _reply(op, 0, []);
      case 0x04: // FLASH_END
        _reply(op, 0, []);
      case 0x13: // SPI_FLASH_MD5
        final off = d.getUint32(0, Endian.little);
        final size = d.getUint32(4, Endian.little);
        var hex = crypto.md5.convert(flash.sublist(off, off + size)).toString();
        if (corruptMd5) hex = '0$hex'.substring(0, 32);
        _reply(op, 0, ascii.encode(hex));
      case 0x0E: // READ_FLASH (ROM)
        final off = d.getUint32(0, Endian.little);
        final n = d.getUint32(4, Endian.little);
        _reply(op, 0, flash.sublist(off, off + n));
      default:
        _reply(op, 0, [], status: 1, code: 5);
    }
  }
}

Uint8List image(String family, int size, {String project = '', String version = ''}) {
  final b = Uint8List(size);
  for (var i = 0; i < size; i++) {
    b[i] = (i * 7 + 3) & 0xFF;
  }
  b[0] = 0xE9;
  final chip = {'esp32': 0, 'esp32s3': 9, 'esp32c3': 5}[family]!;
  b[12] = chip;
  b[13] = 0;
  if (project.isNotEmpty) {
    final d = ByteData.sublistView(b, 0x20);
    d.setUint32(0, EspAppDesc.magic, Endian.little);
    b.fillRange(0x20 + 16, 0x20 + 80, 0);
    b.setRange(0x20 + 16, 0x20 + 16 + version.length, ascii.encode(version));
    b.setRange(0x20 + 48, 0x20 + 48 + project.length, ascii.encode(project));
  }
  return b;
}

Uint8List partitionTable() {
  Uint8List row(int type, int sub, int off, int size, String label) {
    final r = Uint8List(32);
    r[0] = 0xAA;
    r[1] = 0x50;
    r[2] = type;
    r[3] = sub;
    ByteData.sublistView(r).setUint32(4, off, Endian.little);
    ByteData.sublistView(r).setUint32(8, size, Endian.little);
    r.setRange(12, 12 + label.length, ascii.encode(label));
    return r;
  }

  final md5 = Uint8List(32)..fillRange(0, 32, 0xFF);
  md5[0] = 0xEB;
  md5[1] = 0xEB;
  return Uint8List.fromList([
    ...row(1, 2, 0x9000, 0x6000, 'nvs'),
    ...row(1, 0, 0xF000, 0x2000, 'otadata'),
    ...row(1, 1, 0x11000, 0x1000, 'phy_init'),
    ...row(0, 0x10, 0x20000, 0x200000, 'ota_0'),
    ...md5,
  ]);
}

const boardsJson = '''
[
 {"id":"tdeck","name":"T-Deck","silicon":{"family":"esp32s3","flash_mb":16},
  "firmware":{"flash_port":"native-usb","env":"tdeck","version":"0.4.0"}},
 {"id":"tdongle-s3","name":"T-Dongle-S3","silicon":{"family":"esp32s3","flash_mb":16},
  "firmware":{"flash_port":"native-usb","env":"tdongle","version":"0.4.0"}},
 {"id":"epaper-1in54","name":"ePaper","silicon":{"family":"esp32s3","flash_mb":4},
  "firmware":{"flash_port":"native-usb","env":"epaper","version":"0.1.0"}},
 {"id":"esp32c3-mini","name":"C3 mini","silicon":{"family":"esp32c3","flash_mb":4},
  "firmware":{"flash_port":"native-usb","env":"c3mini","version":"0.1.0"}},
 {"id":"heltec-v3","name":"Heltec V3","silicon":{"family":"esp32s3","flash_mb":8},
  "firmware":{"flash_port":"usb-serial","env":"heltec_v3","version":"0.1.0"}},
 {"id":"generic","name":"generic","silicon":{"family":"esp32","flash_mb":4},
  "firmware":{"flash_port":"usb-serial","env":"generic","version":"0.1.0"}},
 {"id":"sensecap-p1-pro","name":"P1","silicon":{"family":"nrf52","flash_mb":1},
  "firmware":{"flash_port":"uf2","env":"p1pro","version":"0.1.0"}},
 {"id":"kv4p","name":"kv4p","silicon":{"family":"esp32","flash_mb":4},
  "firmware":{"flash_port":"usb-serial","env":"kv4p"}}
]''';

const manifestJson = '''
{"name":"XPRS T-Dongle-S3","version":"0.4.0","new_install_prompt_erase":true,
 "builds":[{"chipFamily":"ESP32-S3","parts":[
   {"path":"firmware.bin","offset":131072},
   {"path":"bootloader.bin","offset":0},
   {"path":"partitions.bin","offset":32768}]}]}''';

void main() {
  group('framing', () {
    test('SLIP escapes END and ESC', () {
      final e = EspRomLoader.slipEncode([0xC0, 0xDB, 0x01]);
      expect(e, [0xC0, 0xDB, 0xDC, 0xDB, 0xDD, 0x01, 0xC0]);
    });
    test('checksum is xor seeded 0xEF', () {
      expect(EspRomLoader.checksum([0xEF]), 0);
      expect(EspRomLoader.checksum([1, 2, 3]), 0xEF ^ 1 ^ 2 ^ 3);
    });
  });

  group('connect and detect', () {
    test('an S3 already in its loader: chip, flash size, SPI params', () async {
      final rom = FakeRom();
      final l = EspRomLoader(rom);
      await rom.open(115200);
      await l.connect();
      expect(await l.detect(), EspFamily.esp32s3);
      expect(l.flashSize, 16 * 1024 * 1024);
      expect(rom.spiSetSize, 16 * 1024 * 1024);
      // SPI_ATTACH carried eight bytes, as a ROM wants.
      final attach = rom.commands.firstWhere((c) => c.$1 == 0x0D);
      expect(attach.$2.length, 8);
    });

    test('a chip that ignores the first syncs is reset and reached', () async {
      final rom = FakeRom(syncsBeforeAnswer: 7);
      final l = EspRomLoader(rom, nativeUsb: true);
      await rom.open(115200);
      await l.connect();
      expect(rom.dtrChanges, greaterThan(0));
    });

    test('a magic nobody knows is named as such', () async {
      final rom = FakeRom(magic: 0x12345678);
      final l = EspRomLoader(rom);
      await rom.open(115200);
      await l.connect();
      expect(l.detect(), throwsA(isA<EspLoaderException>()));
    });
  });

  group('writing', () {
    test('a part goes out in 1 KB blocks, padded, verified by MD5', () async {
      final rom = FakeRom();
      final l = EspRomLoader(rom);
      await rom.open(115200);
      await l.connect();
      await l.detect();
      final img = image('esp32s3', 3 * 1024 + 100);
      final phases = <String>[];
      final l2 = EspRomLoader(rom, onProgress: (p, d, t) => phases.add(p))
        ..family = EspFamily.esp32s3;
      await l2.writePart(EspFlashPart.bytes(0x20000, img, name: 'firmware.bin'));
      expect(rom.beginOffset, 0x20000);
      expect(rom.beginSize, img.length);
      expect(rom.beginBlocks, 4);
      expect(rom.beginLen, 20, reason: 'an S3 ROM wants the encrypt word');
      expect(rom.flash.sublist(0x20000, 0x20000 + img.length), img);
      expect(rom.flash[0x20000 + img.length], 0xFF, reason: 'padding is 0xFF');
      expect(phases.first, 'erasing');
      expect(phases, contains('verifying'));
      final md5s = rom.commands.where((c) => c.$1 == 0x13);
      expect(md5s.length, 1);
    });

    test('a bridge that takes a run of blocks gets sixteen a trip, and a lost answer is sent again', () async {
      final rom = FakeRom()..batched = true;
      final l = EspRomLoader(rom)..family = EspFamily.esp32s3;
      await rom.open(115200);
      await l.connect();
      final img = image('esp32s3', 40 * 1024 + 7);
      var blocks = 0, retries = 0;
      final l2 = EspRomLoader(rom, onBlocks: (b, _, r) {
        blocks += b;
        retries += r;
      })
        ..family = EspFamily.esp32s3;
      rom.batches = 0;
      rom.failDataBlocks = 1; // the first block of the first run is refused once
      await l2.writePart(EspFlashPart.bytes(0x20000, img));
      expect(rom.flash.sublist(0x20000, 0x20000 + img.length), img);
      expect(blocks, 41);
      expect(retries, 1);
      expect(rom.batches, 3, reason: '41 blocks in runs of sixteen');
      expect(l.family, EspFamily.esp32s3);
    });

    test('an ESP32 ROM gets the sixteen-byte FLASH_BEGIN', () async {
      final rom = FakeRom(magic: 0x00F01D83);
      final l = EspRomLoader(rom);
      await rom.open(115200);
      await l.connect();
      await l.detect();
      await l.writePart(EspFlashPart.bytes(0x1000, image('esp32', 512)));
      expect(rom.beginLen, 16);
    });

    test('an MD5 that differs fails the part', () async {
      final rom = FakeRom()..corruptMd5 = true;
      final l = EspRomLoader(rom)..family = EspFamily.esp32s3;
      await rom.open(115200);
      await l.connect();
      expect(
          l.writePart(EspFlashPart.bytes(0x20000, image('esp32s3', 2048))),
          throwsA(predicate((e) => e is EspLoaderException && '$e'.contains('did not verify'))));
    });

    test('one lost block is retried, two in a row fail', () async {
      final rom = FakeRom()..failDataBlocks = 1;
      final l = EspRomLoader(rom)..family = EspFamily.esp32s3;
      await rom.open(115200);
      await l.connect();
      final img = image('esp32s3', 2048);
      await l.writePart(EspFlashPart.bytes(0x20000, img));
      expect(rom.flash.sublist(0x20000, 0x20000 + 2048), img);
      rom.failDataBlocks = 2;
      expect(l.writePart(EspFlashPart.bytes(0x20000, img)),
          throwsA(isA<EspLoaderException>()));
    });

    test('a cancel stops between runs of blocks', () async {
      final rom = FakeRom();
      var cancel = false;
      final l = EspRomLoader(rom, cancelled: () => cancel, onProgress: (p, d, t) {
        if (p == 'writing') cancel = true; // after the first run went out
      })
        ..family = EspFamily.esp32s3;
      await rom.open(115200);
      await l.connect();
      await expectLater(l.writePart(EspFlashPart.bytes(0x20000, image('esp32s3', 40 * 1024))),
          throwsA(isA<EspCancelled>()));
      final sent = rom.commands.where((c) => c.$1 == 0x03).length;
      expect(sent, EspRomLoader.batchBlocks);
    });
  });

  group('reading', () {
    test('the app descriptor names the firmware on the chip', () async {
      final rom = FakeRom();
      final img = image('esp32s3', 0x100, project: 'tdongle_xprs', version: '0.4.0');
      rom.flash.setRange(0x20000, 0x20000 + img.length, img);
      final l = EspRomLoader(rom);
      await rom.open(115200);
      await l.connect();
      final b = await l.readFlash(0x20000, 0x80);
      final d = EspAppDesc.parse(b);
      expect(d?.project, 'tdongle_xprs');
      expect(d?.version, '0.4.0');
      expect(EspAppDesc.parse(Uint8List(0x80)), isNull);
    });
  });

  group('images and partitions', () {
    test('the image header names its chip', () {
      expect(espImageFamily(image('esp32c3', 64)), EspFamily.esp32c3);
      expect(espImageFamily(image('esp32', 64)), EspFamily.esp32);
      expect(espImageFamily(Uint8List(64)), isNull);
    });
    test('the partition table is read row by row to the MD5 row', () {
      final p = espParsePartitions(partitionTable());
      expect(p.length, 4);
      expect(p.where((x) => x.isNvs).single.offset, 0x9000);
      expect(p.where((x) => x.isNvs).single.size, 0x6000);
      expect(p.where((x) => x.isOtaData).single.label, 'otadata');
    });
  });

  group('the job', () {
    test('a wipe writes 0xFF over nvs and otadata, then the parts', () async {
      final rom = FakeRom(flashBytes: 0x40000);
      // Something in NVS and the app area to begin with.
      rom.flash.fillRange(0x9000, 0xF000, 0x42);
      rom.flash.fillRange(0xF000, 0x11000, 0x43);
      rom.flash.fillRange(0x11000, 0x12000, 0x44);
      final job = {
        'kind': 'write',
        'port': 'fake',
        'nativeUsb': true,
        'family': 'esp32s3',
        'parts': <Map<String, Object>>[],
        'wipe': <Map<String, Object>>[
          {'name': 'nvs', 'offset': 0x9000, 'size': 0x6000},
          {'name': 'otadata', 'offset': 0xF000, 'size': 0x2000},
        ],
      };
      final seen = <String>[];
      await runFlashJob(rom, job, (p) {
        final part = p['part'];
        if (part is String) seen.add(part);
      }, () => false);
      expect(rom.flash.sublist(0x9000, 0x11000).every((b) => b == 0xFF), isTrue);
      expect(rom.flash[0x11000], 0x44, reason: 'phy_init untouched');
      expect(seen, ['wipe nvs', 'wipe otadata']);
      expect(rom.opened, isFalse, reason: 'the port is closed after');
    });

    test('an image for another chip is refused before FLASH_BEGIN', () async {
      final rom = FakeRom(magic: 0x6921506F); // a C3
      final job = {
        'kind': 'write',
        'port': 'fake',
        'nativeUsb': true,
        'family': 'esp32s3',
        'parts': <Map<String, Object>>[],
        'wipe': <Map<String, Object>>[],
      };
      await expectLater(runFlashJob(rom, job, (_) {}, () => false),
          throwsA(predicate((e) => '$e'.contains('ESP32-C3'))));
      expect(rom.commands.any((c) => c.$1 == 0x02), isFalse);
    });

    test('a probe reads chip, flash and what runs, then resets', () async {
      final rom = FakeRom();
      final img = image('esp32s3', 0x100, project: 'tdeck_xprs', version: '0.4.0');
      rom.flash.setRange(0x20000, 0x20000 + img.length, img);
      final r = await runFlashJob(
          rom, {'kind': 'probe', 'port': 'fake', 'nativeUsb': true, 'family': '',
            'parts': <Map<String, Object>>[], 'wipe': <Map<String, Object>>[]},
          (_) {}, () => false);
      expect(r['chip'], 'esp32s3');
      expect(r['flashBytes'], 16 * 1024 * 1024);
      expect(r['project'], 'tdeck_xprs');
      expect(rom.commands.any((c) => c.$1 == 0x02), isFalse);
    });
  });

  group('catalogue', () {
    final boards = parseBoards(boardsJson, site: 'https://xprs.dev/firmware');

    test('boards.json is read, uf2 and unversioned boards are not flashable', () {
      expect(boards.length, 8);
      final p1 = boards.firstWhere((b) => b.id == 'sensecap-p1-pro');
      expect(p1.flashable, isFalse);
      expect(boards.firstWhere((b) => b.id == 'kv4p').flashable, isFalse);
      expect(boards.firstWhere((b) => b.id == 'tdeck').flashable, isTrue);
      expect(boards.first.manifestUrl,
          'https://xprs.dev/firmware/models/tdeck/prebuilt/manifest.json');
    });

    test('the manifest gives parts in offset order with absolute urls', () {
      final m = parseManifest(manifestJson,
          baseUrl: 'https://xprs.dev/firmware/models/tdongle-s3/prebuilt')!;
      expect(m.family, EspFamily.esp32s3);
      expect(m.promptErase, isTrue);
      expect(m.parts.map((p) => p.offset).toList(), [0, 0x8000, 0x20000]);
      expect(m.parts.last.url,
          'https://xprs.dev/firmware/models/tdongle-s3/prebuilt/firmware.bin');
    });

    test('the firmware on the chip names its board outright', () {
      final m = matchBoards(
          const FlashProbe('esp32s3', 16 * 1024 * 1024, project: 'tdongle_xprs'), boards);
      expect(m.suggested?.id, 'tdongle-s3');
      expect(m.likely.first.id, 'tdongle-s3');
      expect(m.likely.map((b) => b.id), containsAll(['tdeck', 'tdongle-s3']));
    });

    test('two 16 MB S3 boards and no name: both likely, none suggested', () {
      final m = matchBoards(const FlashProbe('esp32s3', 16 * 1024 * 1024), boards);
      expect(m.suggested, isNull);
      expect(m.likely.map((b) => b.id).toSet(), {'tdeck', 'tdongle-s3'});
    });

    test('a 4 MB C3 has one board', () {
      final m = matchBoards(const FlashProbe('esp32c3', 4 * 1024 * 1024), boards);
      expect(m.suggested?.id, 'esp32c3-mini');
    });

    test('an unknown flash size falls back to the family', () {
      final m = matchBoards(const FlashProbe('esp32s3', 0), boards);
      expect(m.suggested, isNull);
      expect(m.likely.length, 4);
    });

    test('a family with no published firmware fits nothing', () {
      final m = matchBoards(const FlashProbe('esp32c6', 0), boards);
      expect(m.likely, isEmpty);
    });

    test('project names follow the CMake convention', () {
      FlashBoard b(String id, String env) =>
          FlashBoard(id: id, name: id, family: 'esp32', env: env, manifestUrl: '');
      expect(boardOwnsImage(b('esp32c3-mini', 'c3mini'), 'esp32c3_xprs'), isTrue);
      expect(boardOwnsImage(b('generic', 'generic'), 'esp32_generic_xprs'), isTrue);
      expect(boardOwnsImage(b('heltec-v3', 'heltec_v3'), 'heltec_v3_xprs'), isTrue);
      expect(boardOwnsImage(b('tdeck', 'tdeck'), 'tdongle_xprs'), isFalse);
      expect(boardOwnsImage(b('m5stack-core', 'm5stack'), 'm5stack_xprs'), isTrue);
      final named = FlashBoard(
          id: 'x', name: 'x', family: 'esp32', image: 'other_name', manifestUrl: '');
      expect(boardOwnsImage(named, 'other_name'), isTrue);
      expect(boardOwnsImage(named, 'x_xprs'), isFalse);
    });
  });
}
