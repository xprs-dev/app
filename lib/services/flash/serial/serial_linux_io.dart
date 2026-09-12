/// Linux serial over libc termios, through dart:ffi. No library beyond
/// libc, which is always there.
///
/// Ported from geogram's `native_serial_linux.dart`, trimmed to what the ROM
/// loader uses. Every call here blocks the isolate it runs on (`poll`, `read`,
/// `write`), which is why FlashService runs the whole Linux session on a
/// worker isolate (docs/performance.md: nothing blocking on the UI isolate).
/// Reached only from flash_service_io.dart, never from the web build.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'serial_port.dart';

// fcntl.h
const _oRdwr = 0x0002;
const _oNoctty = 0x0100;
const _oNonblock = 0x0800;

// termios.h (Linux, glibc)
const _tcsanow = 0;
const _tcioflush = 2;
const _csize = 0x0030;
const _cs8 = 0x0030;
const _cstopb = 0x0040;
const _cread = 0x0080;
const _parenb = 0x0100;
const _parodd = 0x0200;
const _clocal = 0x0800;
const _crtscts = 0x80000000;
const _vtime = 5;
const _vmin = 6;

// ioctl modem lines
const _tiocmbis = 0x5416;
const _tiocmbic = 0x5417;
const _tiocmDtr = 0x002;
const _tiocmRts = 0x004;

const _pollin = 0x0001;

/// Bxxx constants (asm-generic/termbits.h).
const Map<int, int> _baudCodes = {
  9600: 0x000D,
  19200: 0x000E,
  38400: 0x000F,
  57600: 0x1001,
  115200: 0x1002,
  230400: 0x1003,
  460800: 0x1004,
  500000: 0x1005,
  921600: 0x1007,
  1000000: 0x1008,
  1500000: 0x100A,
  2000000: 0x100B,
};

/// glibc's struct termios (NCCS = 32).
final class _Termios extends Struct {
  @Uint32()
  external int c_iflag;
  @Uint32()
  external int c_oflag;
  @Uint32()
  external int c_cflag;
  @Uint32()
  external int c_lflag;
  @Uint8()
  external int c_line;
  @Array(32)
  external Array<Uint8> c_cc;
  @Uint32()
  external int c_ispeed;
  @Uint32()
  external int c_ospeed;
}

final class _PollFd extends Struct {
  @Int32()
  external int fd;
  @Int16()
  external int events;
  @Int16()
  external int revents;
}

typedef _OpenN = Int32 Function(Pointer<Utf8>, Int32);
typedef _OpenD = int Function(Pointer<Utf8>, int);
typedef _CloseN = Int32 Function(Int32);
typedef _CloseD = int Function(int);
typedef _ReadN = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _ReadD = int Function(int, Pointer<Uint8>, int);
typedef _WriteN = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _WriteD = int Function(int, Pointer<Uint8>, int);
typedef _TcgetattrN = Int32 Function(Int32, Pointer<_Termios>);
typedef _TcgetattrD = int Function(int, Pointer<_Termios>);
typedef _TcsetattrN = Int32 Function(Int32, Int32, Pointer<_Termios>);
typedef _TcsetattrD = int Function(int, int, Pointer<_Termios>);
typedef _TcflushN = Int32 Function(Int32, Int32);
typedef _TcflushD = int Function(int, int);
typedef _TcdrainN = Int32 Function(Int32);
typedef _TcdrainD = int Function(int);
typedef _CfsetspeedN = Int32 Function(Pointer<_Termios>, Uint32);
typedef _CfsetspeedD = int Function(Pointer<_Termios>, int);
typedef _IoctlN = Int32 Function(Int32, Uint64, Pointer<Int32>);
typedef _IoctlD = int Function(int, int, Pointer<Int32>);
typedef _PollN = Int32 Function(Pointer<_PollFd>, Uint64, Int32);
typedef _PollD = int Function(Pointer<_PollFd>, int, int);

class _Libc {
  static _Libc? _one;
  static _Libc get instance => _one ??= _Libc._();

  late final DynamicLibrary _lib;
  late final _OpenD open;
  late final _CloseD close;
  late final _ReadD read;
  late final _WriteD write;
  late final _TcgetattrD tcgetattr;
  late final _TcsetattrD tcsetattr;
  late final _TcflushD tcflush;
  late final _TcdrainD tcdrain;
  late final _CfsetspeedD cfsetispeed;
  late final _CfsetspeedD cfsetospeed;
  late final _IoctlD ioctl;
  late final _PollD poll;

  _Libc._() {
    _lib = DynamicLibrary.process();
    open = _lib.lookupFunction<_OpenN, _OpenD>('open');
    close = _lib.lookupFunction<_CloseN, _CloseD>('close');
    read = _lib.lookupFunction<_ReadN, _ReadD>('read');
    write = _lib.lookupFunction<_WriteN, _WriteD>('write');
    tcgetattr = _lib.lookupFunction<_TcgetattrN, _TcgetattrD>('tcgetattr');
    tcsetattr = _lib.lookupFunction<_TcsetattrN, _TcsetattrD>('tcsetattr');
    tcflush = _lib.lookupFunction<_TcflushN, _TcflushD>('tcflush');
    tcdrain = _lib.lookupFunction<_TcdrainN, _TcdrainD>('tcdrain');
    cfsetispeed = _lib.lookupFunction<_CfsetspeedN, _CfsetspeedD>('cfsetispeed');
    cfsetospeed = _lib.lookupFunction<_CfsetspeedN, _CfsetspeedD>('cfsetospeed');
    ioctl = _lib.lookupFunction<_IoctlN, _IoctlD>('ioctl');
    poll = _lib.lookupFunction<_PollN, _PollD>('poll');
  }
}

/// The USB serial devices sysfs knows: `ttyACM*` (CDC, every native-USB
/// Espressif board) and `ttyUSB*` (CP210x, CH34x, FTDI bridges).
List<SerialDevice> linuxListDevices() {
  final out = <SerialDevice>[];
  final tty = Directory('/sys/class/tty');
  if (!tty.existsSync()) return out;
  final names = tty
      .listSync()
      .map((e) => e.path.split('/').last)
      .where((n) => n.startsWith('ttyACM') || n.startsWith('ttyUSB'))
      .toList()
    ..sort();
  for (final name in names) {
    final sys = '/sys/class/tty/$name';
    var vid = 0, pid = 0;
    var product = '', manufacturer = '', serial = '';
    // The USB device directory sits one or two levels above the interface.
    for (final base in ['$sys/device/..', '$sys/device/../..']) {
      final v = File('$base/idVendor');
      if (!v.existsSync()) continue;
      String readOr(String f) {
        try {
          return File('$base/$f').readAsStringSync().trim();
        } catch (_) {
          return '';
        }
      }

      vid = int.tryParse(readOr('idVendor'), radix: 16) ?? 0;
      pid = int.tryParse(readOr('idProduct'), radix: 16) ?? 0;
      product = readOr('product');
      manufacturer = readOr('manufacturer');
      serial = readOr('serial');
      break;
    }
    final port = '/dev/$name';
    var permitted = true;
    try {
      // A member of dialout can open it; anyone else sees it and cannot.
      // writeOnly, not append: Dart seeks to the end of an append-mode file
      // and a tty cannot seek. O_TRUNC is nothing on a character device.
      final f = File(port).openSync(mode: FileMode.writeOnly);
      f.closeSync();
    } catch (_) {
      permitted = false;
    }
    out.add(SerialDevice(
      id: port,
      port: port,
      product: product,
      manufacturer: manufacturer,
      serial: serial,
      vid: vid,
      pid: pid,
      permitted: permitted,
    ));
  }
  return out;
}

class LinuxSerialPort implements SerialPort {
  final String path;
  int _fd = -1;
  final _c = _Libc.instance;

  LinuxSerialPort(this.path);

  @override
  bool get isOpen => _fd >= 0;

  @override
  Future<void> open(int baud) async {
    if (_fd >= 0) await close();
    final p = path.toNativeUtf8();
    try {
      final fd = _c.open(p, _oRdwr | _oNoctty | _oNonblock);
      if (fd < 0) throw SerialException('cannot open $path');
      _fd = fd;
      if (!_configure(baud)) {
        _c.close(fd);
        _fd = -1;
        throw SerialException('cannot configure $path');
      }
    } finally {
      calloc.free(p);
    }
  }

  bool _configure(int baud) {
    final t = calloc<_Termios>();
    try {
      if (_c.tcgetattr(_fd, t) != 0) return false;
      final r = t.ref;
      r.c_iflag = 0; // raw: no CR/NL mapping, no XON/XOFF
      r.c_oflag = 0;
      r.c_lflag = 0; // no canonical mode, no echo, no signals
      r.c_cflag &= ~(_csize | _parenb | _parodd | _cstopb | _crtscts);
      r.c_cflag |= _cs8 | _cread | _clocal;
      r.c_cc[_vmin] = 0;
      r.c_cc[_vtime] = 0;
      final code = _baudCodes[baud] ?? _baudCodes[115200]!;
      _c.cfsetispeed(t, code);
      _c.cfsetospeed(t, code);
      if (_c.tcsetattr(_fd, _tcsanow, t) != 0) return false;
      _c.tcflush(_fd, _tcioflush);
      return true;
    } finally {
      calloc.free(t);
    }
  }

  @override
  Future<Uint8List> read(int max, int timeoutMs) async {
    if (_fd < 0) throw const SerialException('port closed');
    final pfd = calloc<_PollFd>();
    final buf = calloc<Uint8>(max);
    try {
      pfd.ref.fd = _fd;
      pfd.ref.events = _pollin;
      pfd.ref.revents = 0;
      final n = _c.poll(pfd, 1, timeoutMs);
      if (n <= 0 || (pfd.ref.revents & _pollin) == 0) {
        // POLLERR/POLLHUP with no data: the device went away.
        if (n > 0 && (pfd.ref.revents & 0x18) != 0) {
          throw const SerialException('device unplugged');
        }
        return Uint8List(0);
      }
      final got = _c.read(_fd, buf, max);
      if (got < 0) throw const SerialException('read failed');
      if (got == 0) return Uint8List(0);
      return Uint8List.fromList(buf.asTypedList(got));
    } finally {
      calloc.free(buf);
      calloc.free(pfd);
    }
  }

  @override
  Future<void> write(Uint8List data) async {
    if (_fd < 0) throw const SerialException('port closed');
    final buf = calloc<Uint8>(data.length);
    try {
      buf.asTypedList(data.length).setAll(0, data);
      var off = 0;
      var spins = 0;
      while (off < data.length) {
        final n = _c.write(_fd, buf + off, data.length - off);
        if (n < 0) {
          // EAGAIN on a non-blocking fd: the USB pipe is full, give it a moment.
          if (++spins > 200) throw const SerialException('write stalled');
          await Future<void>.delayed(const Duration(milliseconds: 5));
          continue;
        }
        off += n;
      }
      _c.tcdrain(_fd);
    } finally {
      calloc.free(buf);
    }
  }

  void _modem(int bit, bool on) {
    if (_fd < 0) return;
    final arg = calloc<Int32>();
    try {
      arg.value = bit;
      _c.ioctl(_fd, on ? _tiocmbis : _tiocmbic, arg);
    } finally {
      calloc.free(arg);
    }
  }

  @override
  Future<void> setDtr(bool on) async => _modem(_tiocmDtr, on);

  @override
  Future<void> setRts(bool on) async => _modem(_tiocmRts, on);

  @override
  Future<void> setBaud(int baud) async {
    if (_fd < 0) return;
    _configure(baud);
  }

  @override
  Future<void> flushInput() async {
    if (_fd >= 0) _c.tcflush(_fd, _tcioflush);
  }

  @override
  Future<void> close() async {
    if (_fd >= 0) {
      _c.close(_fd);
      _fd = -1;
    }
  }
}
