/// Flashing a board over USB: the core's one door.
///
/// A wapp asks (scan, probe, fetch, write, cancel) and watches one topic,
/// `core.flash`; it reads the whole state back with hal_flash_state. Serial
/// ports, the ROM loader, the catalogue and the files are all here, never in
/// a wapp (docs/architecture.md: a wapp says what it wants, the core owns
/// every device and every lane).
///
/// Threading: the Linux port blocks in poll/read, so a Linux session is a
/// worker isolate that posts progress back; the Android port is a platform
/// channel, which lives on the main isolate (docs/architecture.md 2), so
/// its session runs there as a chain of awaits, with the bridge taking a
/// run of blocks per trip (transactMany) so an image is a hundred trips and
/// not 1,500. Neither hashes a whole image in one go: the MD5 grows block
/// by block as the bytes go out. `drainStats` feeds the minute `perf:` line
/// so a session's cost is visible (performance.md 8.1).
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../background_service.dart';
import '../log_service.dart';
import '../receive/core_state.dart';
import 'esp_image.dart';
import 'esp_rom_loader.dart';
import 'flash_catalog.dart';
import 'flash_catalog_io.dart';
import 'serial/serial_android.dart';
import 'serial/serial_linux_io.dart';
import 'serial/serial_port.dart';

class FlashPhase {
  static const idle = 'idle';
  static const scanning = 'scanning';
  static const probing = 'probing';
  static const fetching = 'fetching';
  static const writing = 'writing';
  static const verifying = 'verifying';
  static const done = 'done';
  static const failed = 'failed';
}

/// What a session was asked to do, sendable to an isolate.
class _Job {
  final String kind; // probe | write
  final String portId;
  final bool nativeUsb;
  final String family; // expected, for write
  final List<Map<String, Object>> parts; // {name, offset, path}
  final List<Map<String, Object>> wipe; // {name, offset, size}
  const _Job(this.kind, this.portId, this.nativeUsb,
      {this.family = '', this.parts = const [], this.wipe = const []});

  Map<String, Object> toMap() => {
        'kind': kind,
        'port': portId,
        'nativeUsb': nativeUsb,
        'family': family,
        'parts': parts,
        'wipe': wipe,
      };

  static _Job fromMap(Map m) => _Job(
        m['kind'] as String,
        m['port'] as String,
        m['nativeUsb'] as bool,
        family: m['family'] as String? ?? '',
        parts: (m['parts'] as List).cast<Map<String, Object>>(),
        wipe: (m['wipe'] as List).cast<Map<String, Object>>(),
      );
}

class FlashService {
  FlashService._();
  static final FlashService instance = FlashService._();

  final catalog = FlashCatalog();

  String phase = FlashPhase.idle;
  String message = '';
  String error = '';
  List<SerialDevice> devices = const [];
  Map<String, FlashLocal> locals = {};

  /// The device last probed or being written, and what the probe learned.
  SerialDevice? device;
  FlashProbe? probe;
  FlashMatch? match;

  /// The board being fetched or written.
  String boardId = '';
  String partName = '';
  int partIndex = 0;
  int partCount = 0;
  int done = 0;
  int total = 0;

  bool _busy = false;
  bool _cancel = false;
  Isolate? _isolate;
  SendPort? _isolateCtl;
  bool _hooked = false;

  bool get busy => _busy;

  /// What the sessions did since the last drain, for the minute `perf:`
  /// line: blocks and bytes written, block retries, sessions and failures.
  int _statBlocks = 0, _statBytes = 0, _statRetries = 0, _statSessions = 0, _statFailed = 0;

  Map<String, int> drainStats() {
    final m = {
      'sessions': _statSessions,
      'failed': _statFailed,
      'blocks': _statBlocks,
      'bytes': _statBytes,
      'retries': _statRetries,
    };
    _statBlocks = _statBytes = _statRetries = _statSessions = _statFailed = 0;
    return m;
  }

  void _hook() {
    if (_hooked) return;
    _hooked = true;
    if (Platform.isAndroid) {
      AndroidUsbSerial.onDevicesChanged = () => unawaited(scan());
    }
  }

  void _publish() => CoreState.instance.changed(CoreState.flash);

  void _set(String p, {String? msg, String? err}) {
    phase = p;
    if (msg != null) message = msg;
    error = err ?? (p == FlashPhase.failed ? error : '');
    _publish();
  }

  static bool get supported => Platform.isLinux || Platform.isAndroid;

  // ── the verbs ───────────────────────────────────────────────────────

  /// Devices now, and the catalogue (refreshed when stale). Never blocks a
  /// running session.
  /// A scan is not a session: it never touches [phase], [message] or
  /// [error], because a USB attach event fires one at any moment and the
  /// verdict of the probe or write that just ended must survive it. The
  /// wapp reads [scanning] beside the phase.
  bool scanning = false;
  String catalogNote = '';

  Future<void> scan({bool force = false}) async {
    _hook();
    scanning = true;
    _publish();
    try {
      devices = await _listDevices();
      _publish();
      await catalog.refresh(force: force);
      await _loadLocals();
      catalogNote = catalog.boards.isEmpty
          ? (catalog.lastError.isEmpty ? 'No catalogue yet' : catalog.lastError)
          : '';
    } catch (e) {
      catalogNote = 'scan failed: $e';
      LogService.instance.add('flash: scan failed: $e');
    } finally {
      scanning = false;
      _publish();
    }
  }

  Future<void> _loadLocals() async {
    final out = <String, FlashLocal>{};
    for (final b in catalog.boards) {
      final l = await catalog.local(b.id);
      if (l != null) out[b.id] = l;
    }
    locals = out;
  }

  Future<List<SerialDevice>> _listDevices() async {
    // sysfs is read with *Sync calls: a one-shot off the UI isolate.
    if (Platform.isLinux) return BackgroundService.runOffThread(() async => linuxListDevices());
    if (Platform.isAndroid) return AndroidUsbSerial.listDevices();
    return const [];
  }

  SerialDevice? _find(String id) {
    for (final d in devices) {
      if (d.id == id) return d;
    }
    return null;
  }

  Future<bool> _permit(SerialDevice d) async {
    if (d.permitted) return true;
    if (Platform.isAndroid) {
      final ok = await AndroidUsbSerial.requestPermission(d.id);
      if (ok) devices = await _listDevices();
      return ok;
    }
    return false;
  }

  /// Name the chip on [deviceId], its flash, and the firmware it runs.
  Future<bool> probeDevice(String deviceId) async {
    _hook();
    if (_busy) return false;
    final d = _find(deviceId);
    if (d == null) {
      _set(FlashPhase.failed, err: 'No such device');
      return false;
    }
    device = d;
    probe = null;
    match = null;
    if (!await _permit(d)) {
      _set(FlashPhase.failed, err: 'Not allowed to use it');
      return false;
    }
    _busy = true;
    _cancel = false;
    _statSessions++;
    _set(FlashPhase.probing, msg: 'Talking to the board...');
    try {
      final r = await _run(_Job('probe', d.id, d.isNativeUsb));
      final fam = r['chip'] as String? ?? '';
      probe = FlashProbe(fam, (r['flashBytes'] as num?)?.toInt() ?? 0,
          project: r['project'] as String? ?? '', version: r['version'] as String? ?? '');
      match = matchBoards(probe!, catalog.boards);
      LogService.instance.add('flash: probe ${d.port}: ${EspFamily.label(fam)} '
          '${probe!.flashBytes ~/ (1024 * 1024)} MB runs "${probe!.project}" ${probe!.version} '
          'best=${match!.suggested?.id ?? '-'} fits=${match!.likely.map((b) => b.id).join(',')} '
          'catalogue=${catalog.boards.length}');
      final s = match!.suggested;
      _set(FlashPhase.idle,
          msg: s != null
              ? 'Looks like a ${s.name}'
              : match!.likely.isEmpty
                  ? 'No published firmware for a ${EspFamily.label(fam)}'
                  : '${match!.likely.length} boards fit');
      return true;
    } on EspCancelled {
      _set(FlashPhase.idle, msg: 'Stopped');
      return false;
    } catch (e) {
      _statFailed++;
      LogService.instance.add('flash: probe ${d.port} failed: $e');
      _set(FlashPhase.failed, err: '$e');
      return false;
    } finally {
      _busy = false;
      _publish();
    }
  }

  /// Download [id]'s parts.
  Future<bool> fetchBoard(String id) async {
    _hook();
    if (_busy) return false;
    await catalog.load();
    final b = catalog.board(id);
    if (b == null) {
      _set(FlashPhase.failed, err: 'Unknown board');
      return false;
    }
    if (!b.flashable) {
      _set(FlashPhase.failed, err: '${b.name} is not flashed over serial');
      return false;
    }
    _busy = true;
    boardId = id;
    done = 0;
    total = 0;
    _set(FlashPhase.fetching, msg: 'Downloading ${b.name} ${b.version}...');
    try {
      final l = await catalog.fetch(id, (d, t) {
        done = d;
        total = t;
        _publish();
      });
      locals[id] = l;
      _set(FlashPhase.idle, msg: '${b.name} ${l.version} downloaded');
      return true;
    } catch (e) {
      LogService.instance.add('flash: fetch $id failed: $e');
      _set(FlashPhase.failed, err: '$e');
      return false;
    } finally {
      _busy = false;
      _publish();
    }
  }

  /// Write the downloaded [id] to [deviceId]. [wipe] erases the NVS and OTA
  /// data partitions first (a new station: key, owner and WiFi gone).
  Future<bool> writeBoard(String deviceId, String id, {bool wipe = false}) async {
    _hook();
    if (_busy) return false;
    final d = _find(deviceId);
    if (d == null) {
      _set(FlashPhase.failed, err: 'No such device');
      return false;
    }
    final b = catalog.board(id);
    final l = locals[id] ?? await catalog.local(id);
    if (b == null || l == null) {
      _set(FlashPhase.failed, err: 'Download it first');
      return false;
    }
    if (!await _permit(d)) {
      _set(FlashPhase.failed, err: 'Not allowed to use it');
      return false;
    }
    final fam = EspFamily.fromWebTools(b.family) ?? l.family;
    final wipeList = <Map<String, Object>>[];
    if (wipe) {
      // The partition table image says exactly where NVS and otadata sit.
      FlashLocalPart? pt;
      for (final p in l.parts) {
        if (p.offset == 0x8000) pt = p;
      }
      if (pt != null) {
        // arch-ignore: no-whole-file-read the partition table is 3 KB by the format (0xC00 max), never an image
        final bytes = await File(pt.path).readAsBytes();
        for (final part in espParsePartitions(bytes)) {
          if (part.isNvs || part.isOtaData) {
            wipeList.add({'name': part.label, 'offset': part.offset, 'size': part.size});
          }
        }
      }
      if (wipeList.isEmpty) {
        _set(FlashPhase.failed, err: 'No partition table to find the settings in');
        return false;
      }
    }
    device = d;
    boardId = id;
    _busy = true;
    _cancel = false;
    _statSessions++;
    partIndex = 0;
    partCount = l.parts.length + wipeList.length;
    done = 0;
    total = 0;
    _set(FlashPhase.writing, msg: 'Writing ${b.name} ${l.version}...');
    try {
      await _run(_Job('write', d.id, d.isNativeUsb,
          family: fam,
          parts: [
            for (final p in l.parts) {'name': p.name, 'offset': p.offset, 'path': p.path, 'sha256': p.sha256},
          ],
          wipe: wipeList));
      _set(FlashPhase.done, msg: '${b.name} ${l.version} written and verified. It is restarting.');
      LogService.instance.add('flash: ${b.id} ${l.version} -> ${d.port}${wipe ? ' (wiped)' : ''}');
      return true;
    } on EspCancelled {
      _set(FlashPhase.failed, err: 'Stopped before it finished: the board may not boot until flashed again');
      return false;
    } catch (e) {
      _statFailed++;
      _set(FlashPhase.failed, err: '$e');
      LogService.instance.add('flash: ${b.id} -> ${d.port} failed: $e');
      return false;
    } finally {
      _busy = false;
      _publish();
      unawaited(Future<void>.delayed(const Duration(seconds: 2), () async {
        // The CDC device re-enumerates after the reset.
        devices = await _listDevices();
        _publish();
      }));
    }
  }

  void cancel() {
    _cancel = true;
    _isolateCtl?.send('cancel');
    // A session stuck in a long ROM erase cannot look at the flag: give it
    // five seconds to stop on its own, then pull the isolate.
    final iso = _isolate;
    final pending = _pending;
    if (iso != null && pending != null) {
      Timer(const Duration(seconds: 5), () {
        if (_isolate == iso && !pending.isCompleted) {
          iso.kill(priority: Isolate.immediate);
          pending.completeError(const EspCancelled());
        }
      });
    }
  }

  // ── running a job where the port lives ──────────────────────────────

  Future<Map<String, Object>> _run(_Job job) async {
    if (Platform.isLinux) return _runLinux(job);
    if (Platform.isAndroid) {
      // A platform channel lives on the main isolate (docs/architecture.md
      // 2), so the Android session does too: a chain of awaits, nothing
      // heavier than a block's checksum, and few trips (transactMany).
      return runFlashJob(AndroidSerialPort(job.portId), job.toMap(), _onProgress, () => _cancel);
    }
    throw const EspLoaderException('No USB serial on this platform');
  }

  void _onProgress(Map<String, Object> p) {
    final ph = p['phase'] as String?;
    if (ph != null) phase = ph;
    final b = (p['blocks'] as num?)?.toInt();
    if (b != null) {
      _statBlocks += b;
      _statBytes += (p['bytes'] as num?)?.toInt() ?? 0;
      _statRetries += (p['retries'] as num?)?.toInt() ?? 0;
    }
    partName = p['part'] as String? ?? partName;
    partIndex = (p['partIndex'] as num?)?.toInt() ?? partIndex;
    done = (p['done'] as num?)?.toInt() ?? done;
    total = (p['total'] as num?)?.toInt() ?? total;
    final m = p['message'] as String?;
    if (m != null) message = m;
    _publish();
  }

  Completer<Map<String, Object>>? _pending;

  Future<Map<String, Object>> _runLinux(_Job job) async {
    final rx = ReceivePort();
    final result = Completer<Map<String, Object>>();
    _pending = result;
    _isolateCtl = null;
    rx.listen((msg) {
      if (msg is SendPort) {
        _isolateCtl = msg;
        if (_cancel) msg.send('cancel');
        return;
      }
      if (msg is List && msg.length == 2 && !result.isCompleted) {
        // An uncaught error in the isolate (onError): [error, stack].
        result.completeError(EspLoaderException('${msg[0]}'));
        return;
      }
      if (msg is Map) {
        final m = msg.cast<String, Object>();
        switch (m['type']) {
          case 'progress':
            _onProgress(m);
          case 'done':
            if (!result.isCompleted) result.complete((m['result'] as Map?)?.cast<String, Object>() ?? {});
          case 'error':
            if (!result.isCompleted) {
              result.completeError(m['cancelled'] == true
                  ? const EspCancelled()
                  : EspLoaderException(m['error'] as String? ?? 'failed'));
            }
          case 'log':
            LogService.instance.add(m['line'] as String? ?? '');
        }
      }
    });
    try {
      _isolate = await Isolate.spawn(_linuxSessionMain, [rx.sendPort, job.toMap()],
          debugName: 'flash-session', errorsAreFatal: true, onError: rx.sendPort);
      return await result.future;
    } finally {
      rx.close();
      _isolate = null;
      _isolateCtl = null;
      _pending = null;
    }
  }

  Map<String, Object> stateJson() {
    final d = device;
    final p = probe;
    final m = match;
    // Scalars first, the rows last: a wapp that scans for one key stops at
    // the head instead of walking every board's row to find "part".
    return {
      'phase': phase,
      'busy': _busy,
      'scanning': scanning,
      'catalogNote': catalogNote,
      'message': message,
      'error': error,
      'supported': supported,
      'catalogAt': catalog.fetchedAt?.millisecondsSinceEpoch ?? 0,
      'board': boardId,
      'part': partName,
      'partIndex': partIndex,
      'partCount': partCount,
      'done': done,
      'total': total,
      'devices': [for (final x in devices) x.toJson()],
      'boards': [
        for (final b in catalog.boards)
          {
            ...b.toJson(),
            'local': locals[b.id]?.version ?? '',
            'localBytes': locals[b.id]?.totalBytes ?? 0,
          },
      ],
      'device': d == null
          ? const <String, Object>{}
          : {
              ...d.toJson(),
              'chip': p?.family ?? '',
              'chipLabel': p == null ? '' : EspFamily.label(p.family),
              'flashBytes': p?.flashBytes ?? 0,
              'runs': p?.project ?? '',
              'runsVersion': p?.version ?? '',
              'suggested': m?.suggested?.id ?? '',
              'likely': m == null ? '' : m.likely.map((b) => b.id).join(' '),
            },
    };
  }
}

// ── the session itself, on whichever isolate holds the port ───────────

/// Probe or write through [port] as [jobMap] says. Progress maps carry
/// phase/part/partIndex/done/total/message. Returns the probe's facts.
Future<Map<String, Object>> runFlashJob(
    SerialPort port,
    Map<String, Object> jobMap,
    void Function(Map<String, Object>) progress,
    bool Function() cancelled) async {
  final job = _Job.fromMap(jobMap);
  final loader = EspRomLoader(port,
      nativeUsb: job.nativeUsb,
      cancelled: cancelled,
      onProgress: (ph, d, t) => progress({'phase': ph, 'done': d, 'total': t}),
      onBlocks: (n, bytes, retries) =>
          progress({'blocks': n, 'bytes': bytes, 'retries': retries}));
  await port.open(115200);
  try {
    progress({'phase': FlashPhase.probing, 'message': 'Waiting for the board...'});
    await loader.connect();
    final fam = await loader.detect();
    final result = <String, Object>{
      'chip': fam,
      'flashBytes': loader.flashSize,
      'flashId': loader.flashId,
    };
    if (job.kind == 'probe') {
      progress({'message': 'Reading what it runs...'});
      // The app is wherever the partition table puts it, and after an OTA
      // update it is in the other slot: read the table, then the
      // descriptor of every app partition, and take the first that is one.
      final offsets = <int>[];
      try {
        final table = await loader.readFlash(0x8000, 0xC00);
        for (final p in espParsePartitions(table)) {
          if (p.type == 0 && p.size > 0x100) offsets.add(p.offset);
        }
      } on EspLoaderException {
        // No readable table: the usual places.
      }
      for (final off in [0x20000, 0x10000]) {
        if (!offsets.contains(off)) offsets.add(off);
      }
      for (final off in offsets) {
        try {
          final b = await loader.readFlash(off, 0x80);
          final desc = EspAppDesc.parse(b);
          if (desc != null) {
            result['project'] = desc.project;
            result['version'] = desc.version;
            result['appOffset'] = off;
            break;
          }
        } on EspLoaderException {
          break;
        }
      }
      await loader.hardReset();
      return result;
    }
    if (job.family.isNotEmpty && job.family != fam) {
      throw EspLoaderException(
          'this image is for ${EspFamily.label(job.family)}, the board is ${EspFamily.label(fam)}');
    }
    if (!job.nativeUsb) {
      try {
        await loader.changeBaud(460800);
      } on EspLoaderException {
        // Stay at 115200; slower, not wrong.
      }
    }
    var index = 0;
    final count = job.wipe.length + job.parts.length;
    for (final w in job.wipe) {
      final size = (w['size'] as num).toInt();
      final off = (w['offset'] as num).toInt();
      final name = w['name'] as String? ?? 'settings';
      progress({'phase': FlashPhase.writing, 'part': 'wipe $name', 'partIndex': ++index, 'partCount': count, 'done': 0, 'total': size,
        'message': 'Wiping $name...'});
      await loader.writePart(EspFlashPart.blank(off, size, name: name), verify: false);
    }
    for (final p in job.parts) {
      final name = p['name'] as String;
      final off = (p['offset'] as num).toInt();
      final file = File(p['path'] as String);
      final size = await file.length();
      // The image is read a block at a time straight off the file: the
      // loader wants 1 KB per command and the file never comes up whole.
      final raf = await file.open();
      try {
        if (off >= 0x10000) {
          await raf.setPosition(0);
          final f = espImageFamily(await raf.read(24));
          if (f != null && f != fam) {
            throw EspLoaderException('$name is built for ${EspFamily.label(f)}, the board is ${EspFamily.label(fam)}');
          }
        }
        progress({'phase': FlashPhase.writing, 'part': name, 'partIndex': ++index, 'partCount': count, 'done': 0, 'total': size,
          'message': 'Writing $name (${(size / 1024).round()} KB)...'});
        await loader.writePart(EspFlashPart(off, size, (s, n) async {
          await raf.setPosition(s);
          return raf.read(n);
        }, name: name));
      } finally {
        await raf.close();
      }
    }
    progress({'message': 'Restarting the board...'});
    await loader.reboot();
    return result;
  } finally {
    await port.close();
  }
}

Future<void> _linuxSessionMain(List<Object> args) => _sessionMain(args, (id) => LinuxSerialPort(id));

Future<void> _sessionMain(List<Object> args, SerialPort Function(String) openPort) async {
  final out = args[0] as SendPort;
  final jobMap = (args[1] as Map).cast<String, Object>();
  final ctl = ReceivePort();
  var cancelled = false;
  ctl.listen((m) {
    if (m == 'cancel') cancelled = true;
  });
  out.send(ctl.sendPort);
  final portId = jobMap['port'] as String;
  var last = 0;
  try {
    final r = await runFlashJob(openPort(portId), jobMap, (p) {
      // At most ten progress posts a second, plus every phase change.
      final now = DateTime.now().millisecondsSinceEpoch;
      if (p.containsKey('phase') || p.containsKey('message') || p.containsKey('blocks') ||
          now - last >= 100 || p['done'] == p['total']) {
        last = now;
        out.send({'type': 'progress', ...p});
      }
    }, () => cancelled);
    out.send({'type': 'done', 'result': r});
  } on EspCancelled {
    out.send({'type': 'error', 'cancelled': true});
  } catch (e) {
    out.send({'type': 'error', 'error': '$e'});
  } finally {
    ctl.close();
  }
}
