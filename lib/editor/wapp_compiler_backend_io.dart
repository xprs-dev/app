/*
 * The C compiler wapps are built with, on every device: xcc (a small C
 * compiler and linker that writes WebAssembly itself) compiled to WASI and
 * bundled with the app, run by the app's own WASM runtime. Nothing is
 * installed; a phone and a desktop build the same bytes.
 *
 *   assets/compiler/cc.wasm   the compiler, entered by its xprs_run export
 *                             (a _start would run inside the runtime's
 *                             build(), before its output could be read);
 *                             it writes its messages to /tmp/cc.log
 *   assets/compiler/usr.zip   what it reads at /usr: its headers and C
 *                             library, the XPRS headers (xprs/) and the
 *                             test runner (xprs/sdk/)
 *
 * Both come from tool/build_compiler.sh. usr.zip is unpacked once per
 * version into the temp folder, because the compiler reads files by path.
 *
 * A run blocks the thread it is on (the runtime has only a synchronous
 * call), so it happens on a worker isolate, never the UI's. The worker keeps
 * the compiled module between builds and exits after five idle minutes.
 *
 * The compiler sees /usr, the build's /work and /tmp, and /hal and /sdk:
 * wapps include the XPRS headers as they sit beside them in the apps tree
 * ("../hal/xprs_wasm_hal.h"). Nothing else of the device is visible to it.
 * The web build has no compiler (wapp_compiler_backend_web.dart).
 */

import 'dart:async';
import 'dart:io' show Directory, File;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:wasm_run/wasm_run.dart';

import 'package:xprs_core/src/profile/storage_paths.dart'
    show wappPackageStorage;

import '../profile/profile_storage.dart';
import 'wapp_compiler_service.dart';

CompilerBackend makeCompilerBackend() => const BundledCompilerBackend();

/// The outcome of one build: [code] 0 when it linked. The output is in the
/// work folder; the caller reads it through its storage.
class CompilerRun {
  final int code;
  final String log;
  final int ms;
  const CompilerRun(this.code, this.log, this.ms);
}

/// The bundled compiler's worker.
class BundledCompiler {
  BundledCompiler._();
  static final BundledCompiler instance = BundledCompiler._();

  SendPort? _worker;
  Isolate? _isolate;
  Timer? _idle;
  static const _idleFor = Duration(minutes: 5);

  /// Build [sources] (relative to [workDir], seen as /work, or guest paths
  /// under /usr) into `/work/<out>` with [flags]. [workDir] is an absolute
  /// host folder.
  Future<CompilerRun> build({
    required String workDir,
    required List<String> flags,
    required List<String> sources,
    String out = 'output.wasm',
  }) async {
    final sw = Stopwatch()..start();
    final SendPort port;
    try {
      port = await _port();
    } catch (e) {
      return CompilerRun(-1, 'compiler failed to start: $e', 0);
    }
    final reply = ReceivePort();
    port.send(<String, Object?>{
      'reply': reply.sendPort,
      'work': workDir,
      'args': <String>[
        'cc',
        ...flags,
        '-o',
        '/work/$out',
        for (final s in sources) s.startsWith('/') ? s : '/work/$s',
      ],
    });
    final res = await reply.first as Map;
    reply.close();
    _armIdle();
    return CompilerRun(
      res['code'] as int,
      res['log'] as String,
      sw.elapsedMilliseconds,
    );
  }

  /// The worker, started with the assets: the asset bundle is read here, on
  /// the isolate that owns it, and handed over without a copy.
  Future<SendPort> _port() async {
    final p = _worker;
    if (p != null) return p;
    final wasm = await rootBundle.load('assets/compiler/cc.wasm');
    final usr = await rootBundle.load('assets/compiler/usr.zip');
    final ready = ReceivePort();
    _isolate = await Isolate.spawn(_workerMain, <Object>[
      ready.sendPort,
      TransferableTypedData.fromList([wasm.buffer.asUint8List()]),
      TransferableTypedData.fromList([usr.buffer.asUint8List()]),
    ], debugName: 'wapp-compiler');
    final first = await ready.first;
    ready.close();
    if (first is! SendPort) throw StateError('$first');
    return _worker = first;
  }

  void _armIdle() {
    _idle?.cancel();
    _idle = Timer(_idleFor, () {
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      _worker = null;
    });
  }
}

// ── Worker isolate ──────────────────────────────────────────────────────

Future<void> _workerMain(List<Object> start) async {
  final ready = start[0] as SendPort;
  final WasmModule module;
  final String usr;
  try {
    final wasm = (start[1] as TransferableTypedData).materialize();
    final zip = (start[2] as TransferableTypedData).materialize();
    usr = await _unpackUsr(zip.asUint8List());
    module = await compileWasmModule(wasm.asUint8List());
  } catch (e) {
    ready.send('$e');
    return;
  }
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  await for (final msg in inbox) {
    final job = msg as Map;
    final reply = job['reply'] as SendPort;
    try {
      reply.send(
        await _run(
          module,
          usr,
          job['work'] as String,
          (job['args'] as List).cast<String>(),
        ),
      );
    } catch (e) {
      reply.send({'code': -1, 'log': 'compiler failed to start: $e'});
    }
  }
}

/// usr.zip unpacked into the temp folder, once per version (named by its
/// checksum): written to a fresh folder and renamed into place, so a build
/// never sees half of it.
Future<String> _unpackUsr(Uint8List zip) async {
  final id = getCrc32(zip).toRadixString(16);
  final dir = Directory('${Directory.systemTemp.path}/xprs-compiler-$id');
  if (await dir.exists()) return dir.path;
  final tmp = await Directory.systemTemp.createTemp('xprs-compiler-');
  for (final f in ZipDecoder().decodeBytes(zip)) {
    if (!f.isFile) continue;
    final out = File('${tmp.path}/${f.name}');
    await out.parent.create(recursive: true);
    await out.writeAsBytes(f.content as List<int>);
  }
  try {
    await tmp.rename(dir.path);
  } catch (_) {
    // Another worker got there first.
    await tmp.delete(recursive: true);
  }
  return dir.path;
}

Future<Map<String, Object>> _run(
  WasmModule module,
  String usr,
  String work,
  List<String> argv,
) async {
  final tmp = Directory('$work/.tmp');
  await tmp.create();
  final inst = await module
      .builder(
        wasiConfig: WasiConfig(
          args: argv,
          preopenedDirs: [
            PreopenedDir(wasmGuestPath: '/usr', hostPath: usr),
            PreopenedDir(wasmGuestPath: '/work', hostPath: work),
            PreopenedDir(wasmGuestPath: '/tmp', hostPath: tmp.path),
            PreopenedDir(wasmGuestPath: '/hal', hostPath: '$usr/xprs'),
            PreopenedDir(wasmGuestPath: '/sdk', hostPath: '$usr/xprs/sdk'),
          ],
          webBrowserFileSystem: const {},
        ),
      )
      .build();
  var code = 0;
  var trap = '';
  try {
    inst.getFunction('xprs_run')!.call(const []);
  } catch (e) {
    // wasmtime reports proc_exit as "Exited with i32 exit status N".
    final m = RegExp(r'exit status\s+(\d+)').firstMatch('$e');
    if (m != null) {
      code = int.parse(m.group(1)!);
    } else {
      code = -1;
      trap = '\n$e\n';
    }
  }
  final log = File('${tmp.path}/cc.log');
  final text = await log.exists() ? await log.readAsString() : '';
  return {'code': code, 'log': text + trap};
}

// ── The editor's backend ────────────────────────────────────────────────

/// [CompilerBackend] on the bundled compiler. xcc has no optimiser, so a
/// module is larger and slower than an optimised desktop build would be;
/// the published wapps are still built with each wapp's Makefile.
class BundledCompilerBackend implements CompilerBackend {
  const BundledCompilerBackend();

  @override
  String get name => 'xcc';

  @override
  bool get isAvailable => true;

  static const _common = <String>[
    '-I/usr/xprs',
    '-Wall',
    '-DNDEBUG',
    // A wapp has no main: the host calls its exports.
    '--entry-point=',
    // The desktop build's size; xcc's own (8 KB) is too small for wapps.
    '--stack-size=65536',
  ];

  /// A plain scratch folder for one build. Not the profile's storage: an
  /// encrypted profile keeps a wapp's data inside its store, where the
  /// compiler, reading files by path, finds nothing. A wapp's source is
  /// public like its package, which is stored unencrypted too.
  static Future<(Directory, ProfileStorage)> _scratch() async {
    final dir = await Directory.systemTemp.createTemp('wapp-build-');
    return (dir, wappPackageStorage(dir.path));
  }

  @override
  Future<CompileResult> compile({
    required String source,
    required ProfileStorage pkg,
    required ProfileStorage workStorage,
  }) async {
    final (dir, work) = await _scratch();
    try {
      await work.writeString('source.c', source);
      final b = await BundledCompiler.instance.build(
        workDir: dir.path,
        flags: [
          ..._common,
          '-e',
          'module_init,module_tick,module_handle_event,module_destroy,'
              'module_tick_interval_ms',
        ],
        sources: const ['source.c'],
      );
      return _result(b, await work.readBytes('output.wasm'));
    } finally {
      await dir.delete(recursive: true);
    }
  }

  @override
  Future<CompileResult> compileTests({
    required List<String> testSources,
    required ProfileStorage workStorage,
  }) async {
    if (testSources.isEmpty) {
      return CompileResult.failure('no tests/*.c sources to build');
    }
    final (dir, work) = await _scratch();
    try {
      // A test reaches the wapp's code by `#include "../main.c"`: lay the
      // wapp's own sources out beside tests/ as they are on disk.
      await Directory('${dir.path}/tests').create();
      final names = <String>[];
      final wapps = <String>{};
      for (final src in testSources) {
        final f = File(src);
        final n = 'tests/${f.uri.pathSegments.last}';
        await f.copy('${dir.path}/$n');
        names.add(n);
        wapps.add(f.parent.parent.path);
      }
      for (final w in wapps) {
        await for (final e in Directory(w).list()) {
          final name = e.uri.pathSegments.last;
          if (e is File && (name.endsWith('.c') || name.endsWith('.h'))) {
            await e.copy('${dir.path}/$name');
          }
        }
      }
      final b = await BundledCompiler.instance.build(
        workDir: dir.path,
        flags: [
          ..._common,
          '-I/usr/xprs/sdk',
          '-DWAPP_TESTING',
          '-e',
          'module_run_tests',
        ],
        sources: [...names, '/usr/xprs/sdk/wapp_test.c'],
        out: 'tests.wasm',
      );
      return _result(b, await work.readBytes('tests.wasm'));
    } finally {
      await dir.delete(recursive: true);
    }
  }

  /// [wasm] is the output read back through the work storage (a wapp's
  /// module is tens of kilobytes).
  static CompileResult _result(CompilerRun b, Uint8List? wasm) =>
      b.code == 0 && wasm != null && wasm.isNotEmpty
      ? CompileResult(
          ok: true,
          wasmBytes: wasm,
          stderr: b.log,
          durationMs: b.ms,
        )
      : CompileResult(
          ok: false,
          stderr: b.log,
          exitCode: b.code,
          durationMs: b.ms,
          error: b.code == -1 ? b.log : 'the compiler exited with ${b.code}',
        );
}
