/*
 * Compiling a wapp with the Compiler add-on (compiler_addon.dart): xcc, a
 * small C compiler and linker that writes WebAssembly itself, compiled to
 * WASI (media/cc.wasm, about 350 KB) and run by the app's own WASM runtime,
 * so a phone builds C with nothing installed but an ordinary wapp.
 *
 * A run blocks the thread it is on (the runtime has only a synchronous
 * call), so it happens on a worker isolate, never the UI's. The worker keeps
 * the compiled module between builds and exits after five idle minutes.
 *
 * The compiler sees three folders: /usr (the add-on's C headers and library,
 * and the XPRS headers in /usr/xprs), /work (this build's sources and
 * output) and /tmp (its object files, inside the work folder). Nothing else
 * of the device is visible to it.
 */

import 'dart:async';
import 'dart:io' show File, Directory;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:wasm_run/wasm_run.dart';

import 'package:xprs_core/src/profile/storage_paths.dart'
    show wappPackageStorage;

import '../profile/profile_storage.dart';
import 'compiler_addon.dart';
import 'wapp_compiler_service.dart';

/// The outcome of one build: [code] 0 when it linked. The output is in the
/// work folder; the caller reads it through its storage.
class AddonBuild {
  final int code;
  final String log;
  final int ms;
  const AddonBuild(this.code, this.log, this.ms);
}

class AddonCompiler {
  AddonCompiler._();
  static final AddonCompiler instance = AddonCompiler._();

  SendPort? _worker;
  Isolate? _isolate;
  Timer? _idle;
  static const _idleFor = Duration(minutes: 5);

  /// Build [sources] (relative to [workDir], seen as /work, or guest paths
  /// under /usr) into `/work/<out>` with [flags]. [workDir] is an absolute
  /// host folder.
  Future<AddonBuild> build({
    required String workDir,
    required List<String> flags,
    required List<String> sources,
    String out = 'output.wasm',
  }) async {
    final dir = providerDir(wappBuildFunctionality);
    if (dir == null) {
      return const AddonBuild(-1, 'No installed wapp provides wapp.build.', 0);
    }
    final wasm = '$dir/media/cc.wasm';
    final usr = '$dir/media/usr';
    if (!await File(wasm).exists() || !await Directory(usr).exists()) {
      return const AddonBuild(
        -1,
        'The wapp.build provider is incomplete (media/cc.wasm, media/usr).',
        0,
      );
    }
    final sw = Stopwatch()..start();
    final port = await _port();
    final reply = ReceivePort();
    port.send(<String, Object?>{
      'reply': reply.sendPort,
      'wasm': wasm,
      'usr': usr,
      'work': workDir,
      'args': <String>[
        'cc',
        ...flags,
        '-o',
        '/work/$out',
        // Relative to /work, or a guest path as given (/usr/xprs/...).
        for (final s in sources) s.startsWith('/') ? s : '/work/$s',
      ],
    });
    final res = await reply.first as Map;
    reply.close();
    _armIdle();
    return AddonBuild(
      res['code'] as int,
      res['log'] as String,
      sw.elapsedMilliseconds,
    );
  }

  Future<SendPort> _port() async {
    final p = _worker;
    if (p != null) return p;
    final ready = ReceivePort();
    _isolate = await Isolate.spawn(
      _workerMain,
      ready.sendPort,
      debugName: 'compiler-addon',
    );
    final port = await ready.first as SendPort;
    ready.close();
    return _worker = port;
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

Future<void> _workerMain(SendPort ready) async {
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  WasmModule? module;
  String? loaded;
  await for (final msg in inbox) {
    final job = msg as Map;
    final reply = job['reply'] as SendPort;
    try {
      final path = job['wasm'] as String;
      if (module == null || loaded != path) {
        // The runtime compiles only from bytes in memory (wasm_run has no
        // compile-from-file): the 350 KB module is read once per worker.
        // arch-ignore: no-whole-file-read wasm_run compiles from bytes only; worker isolate, once per worker
        final bytes = await File(path).readAsBytes();
        module = await compileWasmModule(bytes, config: const ModuleConfig());
        loaded = path;
      }
      reply.send(
        await _run(
          module,
          job['usr'] as String,
          job['work'] as String,
          (job['args'] as List).cast<String>(),
        ),
      );
    } catch (e) {
      reply.send({'code': -1, 'log': 'compiler failed to start: $e'});
    }
  }
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
            // A wapp includes the XPRS headers as they sit beside it in the
            // apps tree: "../hal/xprs_wasm_hal.h", "../sdk/wapp_i18n.h".
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
    // The command's entry, exported under its own name: a `_start` would
    // run inside build(), before its output could be read.
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
  // xprs_run sends the compiler's messages to /tmp/cc.log (the runtime's
  // captured output arrives only some time after the call).
  final log = File('${tmp.path}/cc.log');
  final text = await log.exists() ? await log.readAsString() : '';
  return {'code': code, 'log': text + trap};
}

// ── The editor's backend over the add-on ────────────────────────────────

/// [CompilerBackend] on the Compiler add-on, with the XPRS headers from the
/// add-on's /usr/xprs. xcc has no optimiser: a build is for trying a change
/// on the device; releases are still built with the desktop toolchain.
class AddonCompilerBackend implements CompilerBackend {
  const AddonCompilerBackend();

  @override
  String get name => 'compiler-addon';

  /// Unknown until a build looks (the lookup is async); the build itself
  /// says plainly when the add-on is missing.
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
  /// compiler, reading files by path, finds nothing (measured on a phone:
  /// the compiler exited 1 on a /work it saw empty). A wapp's source is public
  /// like its package, which is stored unencrypted too.
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
      final b = await AddonCompiler.instance.build(
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
      final b = await AddonCompiler.instance.build(
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

  /// [wasm] is the output read back through the work storage, the same path
  /// the desktop backend takes (a wapp's module is tens of kilobytes).
  static CompileResult _result(AddonBuild b, Uint8List? wasm) =>
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
