/// The ESP ROM serial loader protocol, as esptool speaks it without a stub.
///
/// Pure Dart over [SerialPort]: SLIP frames, the command/response shape,
/// the reset sequences that put a chip into download mode, chip detection,
/// flash size, writing parts at offsets, and the MD5 the ROM computes over
/// what was written. No stub means no compression and 1 KB blocks, which is
/// what `--no-stub` gives and what every XPRS board README already pins.
///
/// Numbers and orderings follow esptool (loader.py, reset.py): timeouts per
/// MB, the extra word S2/S3/C3 ROMs want in FLASH_BEGIN, the ROM answering
/// MD5 as 32 hex characters, SPI_ATTACH's eight bytes.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import 'esp_image.dart';
import 'serial/serial_port.dart';

class EspLoaderException implements Exception {
  final String message;
  const EspLoaderException(this.message);
  @override
  String toString() => message;
}

/// Thrown when the caller's [EspRomLoader.cancelled] turned true.
class EspCancelled implements Exception {
  const EspCancelled();
}

/// One region to write: where it goes, how long it is, and a way to read
/// any slice of it. The loader asks for one block at a time, so a 1.5 MB
/// image never sits on the heap whole (docs/performance.md 8.9): a file
/// hands out 1 KB reads, a wipe hands out 0xFF.
class EspFlashPart {
  final int offset;
  final int size;
  final Future<Uint8List> Function(int start, int len) readAt;
  final String name;
  const EspFlashPart(this.offset, this.size, this.readAt, {this.name = ''});

  /// A part held in memory (tests, and the small blank regions of a wipe).
  factory EspFlashPart.bytes(int offset, Uint8List data, {String name = ''}) =>
      EspFlashPart(offset, data.length,
          (s, n) async => Uint8List.sublistView(data, s, s + n),
          name: name);

  /// A region of 0xFF, [size] long: what a wipe writes.
  factory EspFlashPart.blank(int offset, int size, {String name = ''}) =>
      EspFlashPart(offset, size,
          (s, n) async => Uint8List(n)..fillRange(0, n, 0xFF),
          name: name);
}

typedef EspProgress = void Function(String phase, int done, int total);

class _Regs {
  final int base;
  final int usr, usr1, usr2, mosiDlen, misoDlen, w0;
  const _Regs(this.base, this.usr, this.usr1, this.usr2, this.mosiDlen,
      this.misoDlen, this.w0);
}

class EspRomLoader {
  static const _slipEnd = 0xC0;
  static const _slipEsc = 0xDB;
  static const _slipEscEnd = 0xDC;
  static const _slipEscEsc = 0xDD;

  static const _cmdFlashBegin = 0x02;
  static const _cmdFlashData = 0x03;
  static const _cmdFlashEnd = 0x04;
  static const _cmdSync = 0x08;
  static const _cmdWriteReg = 0x09;
  static const _cmdReadReg = 0x0A;
  static const _cmdSpiSetParams = 0x0B;
  static const _cmdSpiAttach = 0x0D;
  static const _cmdReadFlash = 0x0E; // ROM only, 64 bytes a call
  static const _cmdChangeBaud = 0x0F;
  static const _cmdSpiFlashMd5 = 0x13;

  static const _chipMagicReg = 0x40001000;
  static const blockSize = 0x400;
  static const _defaultTimeoutMs = 3000;
  static const _syncTimeoutMs = 100;
  static const _eraseTimeoutPerMb = 30;
  static const _md5TimeoutPerMb = 8;
  static const _statusBytes = 4; // every ESP32-family ROM

  static const _regsEsp32 =
      _Regs(0x3FF42000, 0x1C, 0x20, 0x24, 0x28, 0x2C, 0x80);
  static const _regsS2 = _Regs(0x3F402000, 0x18, 0x1C, 0x20, 0x24, 0x28, 0x58);
  static const _regsS3C3 =
      _Regs(0x60002000, 0x18, 0x1C, 0x20, 0x24, 0x28, 0x58);

  final SerialPort port;
  final bool nativeUsb;
  final EspProgress? onProgress;
  final bool Function()? cancelled;
  final void Function(String)? log;

  String? family;
  int flashSize = 0;
  int flashId = 0;

  /// Bytes read and not yet framed; [_rxPos] is the next one to look at, so
  /// consuming is a cursor move, not a shift of the whole buffer.
  var _rx = Uint8List(0);
  var _rxPos = 0;

  void _rxClear() {
    _rx = Uint8List(0);
    _rxPos = 0;
  }

  EspRomLoader(this.port,
      {this.nativeUsb = false, this.onProgress, this.cancelled, this.log});

  // ── framing ──────────────────────────────────────────────────────────

  static Uint8List slipEncode(List<int> data) {
    final out = <int>[_slipEnd];
    for (final b in data) {
      if (b == _slipEnd) {
        out..add(_slipEsc)..add(_slipEscEnd);
      } else if (b == _slipEsc) {
        out..add(_slipEsc)..add(_slipEscEsc);
      } else {
        out.add(b);
      }
    }
    out.add(_slipEnd);
    return Uint8List.fromList(out);
  }

  /// XOR of the data seeded with 0xEF, the loader's block checksum.
  static int checksum(List<int> data) {
    var c = 0xEF;
    for (final b in data) {
      c ^= b;
    }
    return c & 0xFF;
  }

  void _check() {
    if (cancelled?.call() == true) throw const EspCancelled();
  }

  /// One SLIP frame's payload, or null at [timeoutMs].
  Future<List<int>?> _readFrame(int timeoutMs) async {
    final deadline = DateTime.now().millisecondsSinceEpoch + timeoutMs;
    var inFrame = false;
    var esc = false;
    final frame = <int>[];
    while (true) {
      if (_rxPos >= _rx.length) {
        final left = deadline - DateTime.now().millisecondsSinceEpoch;
        if (left <= 0) return null;
        final chunk = await port.read(4096, left.clamp(1, timeoutMs));
        if (chunk.isEmpty) continue;
        _rx = chunk;
        _rxPos = 0;
      }
      while (_rxPos < _rx.length) {
        final b = _rx[_rxPos++];
        if (!inFrame) {
          if (b == _slipEnd) inFrame = true;
          continue;
        }
        if (esc) {
          esc = false;
          frame.add(b == _slipEscEnd
              ? _slipEnd
              : b == _slipEscEsc
                  ? _slipEsc
                  : b);
          continue;
        }
        if (b == _slipEsc) {
          esc = true;
        } else if (b == _slipEnd) {
          if (frame.isEmpty) continue; // back-to-back END, an empty frame
          return frame;
        } else {
          frame.add(b);
        }
      }
    }
  }

  /// Send [op] with [data] and wait for its response. Returns (value, data
  /// with the status bytes stripped). A stale response to another op is
  /// skipped, as esptool does, up to a hundred frames.
  Future<(int, Uint8List)> _command(int op, List<int> data,
      {int chk = 0, int timeoutMs = _defaultTimeoutMs, bool checkStatus = true}) async {
    _check();
    final pkt = ByteData(8 + data.length);
    pkt.setUint8(0, 0x00);
    pkt.setUint8(1, op);
    pkt.setUint16(2, data.length, Endian.little);
    pkt.setUint32(4, chk, Endian.little);
    final bytes = pkt.buffer.asUint8List();
    bytes.setRange(8, 8 + data.length, data);
    await port.write(slipEncode(bytes));
    for (var i = 0; i < 100; i++) {
      final f = await _readFrame(timeoutMs);
      if (f == null) throw EspLoaderException('no answer to command 0x${op.toRadixString(16)}');
      if (f.length < 8) continue;
      final r = ByteData.sublistView(Uint8List.fromList(f));
      if (r.getUint8(0) != 0x01 || r.getUint8(1) != op) continue;
      final value = r.getUint32(4, Endian.little);
      final body = Uint8List.fromList(f.sublist(8));
      if (!checkStatus) return (value, body);
      if (body.length < _statusBytes) {
        throw EspLoaderException('short answer to 0x${op.toRadixString(16)}');
      }
      final status = body[body.length - _statusBytes];
      if (status != 0) {
        final code = body[body.length - _statusBytes + 1];
        throw EspLoaderException(
            'command 0x${op.toRadixString(16)} failed, code 0x${code.toRadixString(16)}');
      }
      return (value, Uint8List.sublistView(body, 0, body.length - _statusBytes));
    }
    throw EspLoaderException('no matching answer to 0x${op.toRadixString(16)}');
  }

  // ── entering the loader ──────────────────────────────────────────────

  Future<bool> _sync() async {
    final data = [0x07, 0x07, 0x12, 0x20, ...List.filled(32, 0x55)];
    try {
      await _command(_cmdSync, data, timeoutMs: _syncTimeoutMs, checkStatus: false);
    } on EspLoaderException {
      return false;
    }
    // The ROM answers SYNC eight times; drain the rest.
    for (var i = 0; i < 7; i++) {
      final f = await _readFrame(_syncTimeoutMs);
      if (f == null) break;
    }
    return true;
  }

  Future<void> _sleep(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  /// esptool's ClassicReset: EN through RTS, GPIO0 through DTR, a UART
  /// bridge's transistor pair inverting both.
  Future<void> _classicReset({int extraDelayMs = 0}) async {
    await port.setDtr(false);
    await port.setRts(true);
    await _sleep(100);
    await port.setDtr(true);
    await port.setRts(false);
    await _sleep(50 + extraDelayMs);
    await port.setDtr(false);
  }

  /// esptool's USBJTAGSerialReset for the chip's own USB-serial-JTAG.
  Future<void> _usbJtagReset() async {
    await port.setRts(false);
    await port.setDtr(false);
    await _sleep(100);
    await port.setDtr(true);
    await port.setRts(false);
    await _sleep(100);
    await port.setRts(true);
    await port.setDtr(false);
    await port.setRts(true);
    await _sleep(100);
    await port.setDtr(false);
    await port.setRts(false);
  }

  Future<bool> _tryConnect() async {
    for (var i = 0; i < 5; i++) {
      _check();
      await port.flushInput();
      _rxClear();
      if (await _sync()) return true;
      await _sleep(50);
    }
    return false;
  }

  /// Put the chip in download mode and sync. Tries the chip as it is (it may
  /// be in the loader already), then the reset that fits the port, then the
  /// other one with esptool's longer delay.
  Future<void> connect() async {
    onProgress?.call('syncing', 0, 0);
    if (await _tryConnect()) return;
    final order = nativeUsb
        ? [_usbJtagReset, _classicReset, () => _classicReset(extraDelayMs: 500)]
        : [_classicReset, () => _classicReset(extraDelayMs: 500), _usbJtagReset];
    for (final reset in order) {
      _check();
      await reset();
      await _sleep(50);
      if (await _tryConnect()) return;
    }
    throw const EspLoaderException(
        'the board did not answer. Hold BOOT, tap RESET, release BOOT, then try again');
  }

  // ── registers and the chip ───────────────────────────────────────────

  Future<int> readReg(int addr) async {
    final d = ByteData(4)..setUint32(0, addr, Endian.little);
    final (v, _) = await _command(_cmdReadReg, d.buffer.asUint8List());
    return v;
  }

  Future<void> writeReg(int addr, int value, {int mask = 0xFFFFFFFF, int delayUs = 0}) async {
    final d = ByteData(16)
      ..setUint32(0, addr, Endian.little)
      ..setUint32(4, value, Endian.little)
      ..setUint32(8, mask, Endian.little)
      ..setUint32(12, delayUs, Endian.little);
    await _command(_cmdWriteReg, d.buffer.asUint8List());
  }

  /// Name the chip and learn its flash size. Call once after [connect].
  Future<String> detect() async {
    final magic = await readReg(_chipMagicReg);
    final f = EspFamily.fromMagic(magic);
    if (f == null) {
      throw EspLoaderException('unknown chip, magic 0x${magic.toRadixString(16)}');
    }
    family = f;
    log?.call('flash: chip ${EspFamily.label(f)}');
    await _spiAttach();
    try {
      flashId = await _readFlashId();
      final n = (flashId >> 16) & 0xFF;
      // JEDEC capacity byte: 0x15 = 2 MB ... 0x18 = 16 MB. Anything else is
      // a part we do not know; leave the size 0 and let the caller decide.
      if (n >= 0x12 && n <= 0x1A) flashSize = 1 << n;
    } on EspLoaderException catch (e) {
      log?.call('flash: flash id failed: $e');
    }
    if (flashSize > 0) await _spiSetParams(flashSize);
    return f;
  }

  _Regs get _regs => switch (family) {
        EspFamily.esp32 => _regsEsp32,
        EspFamily.esp32s2 => _regsS2,
        _ => _regsS3C3,
      };

  Future<void> _spiAttach() async {
    // Eight bytes on a ROM loader: the hspi arg and a word it wants zero.
    await _command(_cmdSpiAttach, Uint8List(8));
  }

  Future<void> _spiSetParams(int size) async {
    final d = ByteData(24)
      ..setUint32(0, 0, Endian.little) // fl_id
      ..setUint32(4, size, Endian.little)
      ..setUint32(8, 0x10000, Endian.little) // block
      ..setUint32(12, 0x1000, Endian.little) // sector
      ..setUint32(16, 0x100, Endian.little) // page
      ..setUint32(20, 0xFFFF, Endian.little); // status mask
    await _command(_cmdSpiSetParams, d.buffer.asUint8List());
  }

  /// esptool's run_spiflash_command: a raw SPI command through the SPI
  /// controller's registers, the way flash_id works without a stub.
  Future<int> _spiFlashCommand(int cmd, List<int> data, int readBits) async {
    const usrCommand = 1 << 31;
    const usrMiso = 1 << 28;
    const usrMosi = 1 << 27;
    const cmdUsr = 1 << 18;
    const usr2CommandLenShift = 28;
    final r = _regs;
    final usrReg = r.base + r.usr;
    final usr2Reg = r.base + r.usr2;
    final cmdReg = r.base;
    final w0 = r.base + r.w0;
    final oldUsr = await readReg(usrReg);
    final oldUsr2 = await readReg(usr2Reg);
    var flags = usrCommand;
    if (readBits > 0) flags |= usrMiso;
    if (data.isNotEmpty) flags |= usrMosi;
    if (data.isNotEmpty) await writeReg(r.base + r.mosiDlen, data.length * 8 - 1);
    if (readBits > 0) await writeReg(r.base + r.misoDlen, readBits - 1);
    await writeReg(usrReg, flags);
    await writeReg(usr2Reg, (7 << usr2CommandLenShift) | cmd);
    if (data.isEmpty) {
      await writeReg(w0, 0);
    } else {
      final padded = List<int>.from(data);
      while (padded.length % 4 != 0) {
        padded.add(0);
      }
      final bd = ByteData.sublistView(Uint8List.fromList(padded));
      for (var i = 0; i < padded.length; i += 4) {
        await writeReg(w0 + i, bd.getUint32(i, Endian.little));
      }
    }
    await writeReg(cmdReg, cmdUsr);
    var done = false;
    for (var i = 0; i < 10; i++) {
      if ((await readReg(cmdReg)) & cmdUsr == 0) {
        done = true;
        break;
      }
    }
    if (!done) throw const EspLoaderException('SPI command never finished');
    final status = await readReg(w0);
    await writeReg(usrReg, oldUsr);
    await writeReg(usr2Reg, oldUsr2);
    return status;
  }

  Future<int> _readFlashId() async {
    return (await _spiFlashCommand(0x9F, const [], 24)) & 0xFFFFFF;
  }

  // ── reading a little ─────────────────────────────────────────────────

  /// [len] bytes from flash at [offset], 64 at a call, for a probe that wants
  /// the app descriptor and nothing bigger.
  Future<Uint8List> readFlash(int offset, int len) async {
    final out = BytesBuilder(copy: false);
    var got = 0;
    while (got < len) {
      _check();
      final n = (len - got).clamp(1, 64);
      final d = ByteData(8)
        ..setUint32(0, offset + got, Endian.little)
        ..setUint32(4, n, Endian.little);
      final (_, body) = await _command(_cmdReadFlash, d.buffer.asUint8List());
      if (body.length < n) throw const EspLoaderException('short flash read');
      out.add(body.sublist(0, n));
      got += n;
    }
    return out.takeBytes();
  }

  // ── writing ──────────────────────────────────────────────────────────

  static int _timeoutPerMb(int secondsPerMb, int size) {
    final s = secondsPerMb * size / 1000000;
    return (s * 1000).clamp(_defaultTimeoutMs, 600000).toInt();
  }

  Future<void> changeBaud(int baud) async {
    final d = ByteData(8)
      ..setUint32(0, baud, Endian.little)
      ..setUint32(4, 0, Endian.little); // the ROM wants 0 for the old rate
    await _command(_cmdChangeBaud, d.buffer.asUint8List());
    await port.setBaud(baud);
    await _sleep(50);
    await port.flushInput();
    _rxClear();
  }

  Future<void> _flashBegin(int size, int offset) async {
    final blocks = (size + blockSize - 1) ~/ blockSize;
    final s2s3c3 = family != EspFamily.esp32;
    final d = ByteData(s2s3c3 ? 20 : 16)
      ..setUint32(0, size, Endian.little)
      ..setUint32(4, blocks, Endian.little)
      ..setUint32(8, blockSize, Endian.little)
      ..setUint32(12, offset, Endian.little);
    if (s2s3c3) d.setUint32(16, 0, Endian.little); // not encrypted
    // The ROM erases the region inside FLASH_BEGIN: give it its time.
    await _command(_cmdFlashBegin, d.buffer.asUint8List(),
        timeoutMs: _timeoutPerMb(_eraseTimeoutPerMb, size));
  }

  Future<void> _flashData(Uint8List block, int seq) async {
    final d = ByteData(16 + block.length)
      ..setUint32(0, block.length, Endian.little)
      ..setUint32(4, seq, Endian.little)
      ..setUint32(8, 0, Endian.little)
      ..setUint32(12, 0, Endian.little);
    d.buffer.asUint8List().setRange(16, 16 + block.length, block);
    await _command(_cmdFlashData, d.buffer.asUint8List(), chk: checksum(block));
  }

  Future<void> _flashEnd({required bool reboot}) async {
    final d = ByteData(4)..setUint32(0, reboot ? 0 : 1, Endian.little);
    await _command(_cmdFlashEnd, d.buffer.asUint8List());
  }

  /// The ROM's MD5 over [size] bytes at [offset], as 32 lowercase hex.
  Future<String> flashMd5(int offset, int size) async {
    final d = ByteData(16)
      ..setUint32(0, offset, Endian.little)
      ..setUint32(4, size, Endian.little)
      ..setUint32(8, 0, Endian.little)
      ..setUint32(12, 0, Endian.little);
    final (_, body) = await _command(_cmdSpiFlashMd5, d.buffer.asUint8List(),
        timeoutMs: _timeoutPerMb(_md5TimeoutPerMb, size));
    if (body.length >= 32) {
      // The ROM answers in hex text; a stub would answer 16 raw bytes.
      return String.fromCharCodes(body.sublist(0, 32)).toLowerCase();
    }
    if (body.length >= 16) {
      return body
          .sublist(0, 16)
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
    }
    throw const EspLoaderException('short MD5 answer');
  }

  /// Write [part] and verify it by MD5. Progress counts bytes of this part.
  Future<void> writePart(EspFlashPart part, {bool verify = true}) async {
    final size = part.size;
    if (size == 0) return;
    onProgress?.call('erasing', 0, size);
    await _flashBegin(size, part.offset);
    final blocks = (size + blockSize - 1) ~/ blockSize;
    // The MD5 of what we send, block by block as it goes out, so a 1.5 MB
    // image is never hashed in one go on whichever isolate this runs on.
    final digestIn = _DigestSink();
    final hasher = crypto.md5.startChunkedConversion(digestIn);
    for (var i = 0; i < blocks; i++) {
      _check();
      final start = i * blockSize;
      final end = (start + blockSize).clamp(0, size);
      final slice = await part.readAt(start, end - start);
      if (slice.length != end - start) {
        throw EspLoaderException('${part.name} is shorter than it said');
      }
      var block = slice;
      if (block.length < blockSize) {
        final padded = Uint8List(blockSize)..fillRange(0, blockSize, 0xFF);
        padded.setRange(0, block.length, block);
        block = padded;
      }
      // One retry per block: a frame lost to a USB hiccup is not a failed
      // flash, a second miss is.
      try {
        await _flashData(block, i);
      } on EspLoaderException {
        await _flashData(block, i);
      }
      hasher.add(slice);
      onProgress?.call('writing', end, size);
    }
    hasher.close();
    if (verify) {
      onProgress?.call('verifying', size, size);
      final want = digestIn.value.toString();
      final got = await flashMd5(part.offset, size);
      if (got != want) {
        throw EspLoaderException(
            '${part.name.isEmpty ? 'part' : part.name} at 0x${part.offset.toRadixString(16)} '
            'did not verify: wrote $want, read back $got');
      }
    }
  }

  /// Leave the loader and start the firmware.
  Future<void> reboot() async {
    try {
      await _flashEnd(reboot: true);
    } on EspLoaderException {
      // The ROM may reset before answering; the pulse below covers it.
    }
    await port.setRts(true);
    await _sleep(100);
    await port.setRts(false);
  }

  /// Reset without a FLASH_END (after a probe that wrote nothing).
  Future<void> hardReset() async {
    await port.setDtr(false);
    await port.setRts(true);
    await _sleep(100);
    await port.setRts(false);
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}
