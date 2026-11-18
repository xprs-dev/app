/*
 * Compiling a wapp with the Compiler add-on (compiler_addon.dart): clang and
 * wasm-ld compiled to WASI, run by the app's own WASM runtime, so a phone
 * builds C with nothing installed but an ordinary wapp.
 *
 * WASI cannot start a process, so the clang driver cannot start the
 * compiler and the linker itself. As YoWASP's own runner does, we ask it
 * for its plan (`clang -###`) and run each step it prints (`clang -cc1 ...`,
 * then `wasm-ld ...`) in the same module, chosen by argv[0].
 *
 * A run blocks the thread it is on (the runtime has only a synchronous
 * call), so everything happens on one worker isolate, never the UI's. The
 * worker keeps the loaded module between builds (loading 74 MB of WASM is
 * the expensive part) and exits after five idle minutes to give the memory
 * back.
 *
 * The worker sees two folders: /usr (the add-on's resources and the XPRS
 * headers, read-only by convention) and /work (this build's sources and
 * output). Nothing else of the device is visible to it.
 */

import 'dart:async';
import 'dart:convert';
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

class AddonClang {
  AddonClang._();
  static final AddonClang instance = AddonClang._();

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
    final wasm = '$dir/media/llvm.wasm';
    final usr = '$dir/media/usr';
    if (!await File(wasm).exists() || !await Directory(usr).exists()) {
      return const AddonBuild(
        -1,
        'The wapp.build provider is incomplete (media/llvm.wasm, media/usr).',
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
        'clang',
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
        // compile-from-file), so the 74 MB module is read whole, once per
        // worker, on this worker isolate, and released when compiled.
        // arch-ignore: no-whole-file-read wasm_run compiles from bytes only; worker isolate, once per worker
        final bytes = await File(path).readAsBytes();
        module = await compileWasmModule(bytes, config: const ModuleConfig());
        loaded = path;
      }
      reply.send(
        await _driver(
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

/// clang's driver, done by hand: ask for the plan, run each step.
Future<Map<String, Object>> _driver(
  WasmModule module,
  String usr,
  String work,
  List<String> args,
) async {
  final log = StringBuffer();
  final (planCode, plan) = await _run(module, usr, work, [
    args.first,
    '-###',
    ...args.skip(1),
  ]);
  if (planCode != 0) return {'code': planCode, 'log': plan};
  final steps = parseClangPlan(plan);
  if (steps.isEmpty) return {'code': 1, 'log': plan};
  for (final step in steps) {
    final (code, out) = await _run(module, usr, work, step);
    log.write(out);
    if (code != 0) return {'code': code, 'log': log.toString()};
  }
  return {'code': 0, 'log': log.toString()};
}

Future<(int, String)> _run(
  WasmModule module,
  String usr,
  String work,
  List<String> argv,
) async {
  final inst = await module
      .builder(
        wasiConfig: WasiConfig(
          args: argv,
          preopenedDirs: [
            PreopenedDir(wasmGuestPath: '/usr', hostPath: usr),
            PreopenedDir(wasmGuestPath: '/work', hostPath: work),
          ],
          webBrowserFileSystem: const {},
          // The compile step writes its object file to $TMPDIR (default
          // /tmp, which is not mounted).
          env: const [EnvVariable(name: 'TMPDIR', value: '/work')],
          captureStdout: true,
          captureStderr: true,
        ),
      )
      .build();
  final out = BytesBuilder(copy: false);
  final subs = [inst.stdout.listen(out.add), inst.stderr.listen(out.add)];
  var code = 0;
  try {
    inst.getFunction('_start')!.call(const []);
  } catch (e) {
    // wasmtime reports proc_exit as "Exited with i32 exit status N".
    final m = RegExp(r'exit status\s+(\d+)').firstMatch('$e');
    if (m != null) {
      code = int.parse(m.group(1)!);
    } else {
      code = -1;
      out.add(utf8.encode('\n$e\n'));
    }
  }
  // The captured streams deliver after the call returns: give them a moment,
  // or a failed step reports its exit and not its reason.
  await Future<void>.delayed(const Duration(milliseconds: 100));
  for (final s in subs) {
    await s.cancel();
  }
  return (code, utf8.decode(out.takeBytes(), allowMalformed: true));
}

/// The commands in `clang -###` output: each is one line of double-quoted
/// arguments (`"/usr/bin/clang" "-cc1" ...`), after the version banner. A
/// leading empty argument (the driver's own name, elided) is dropped.
List<List<String>> parseClangPlan(String output) {
  final steps = <List<String>>[];
  for (final line in const LineSplitter().convert(output)) {
    if (!line.startsWith(' "')) continue;
    final args = <String>[];
    var i = 0;
    while (i < line.length) {
      if (line[i] != '"') {
        i++;
        continue;
      }
      final b = StringBuffer();
      i++;
      while (i < line.length && line[i] != '"') {
        if (line[i] == r'\' && i + 1 < line.length) i++;
        b.write(line[i]);
        i++;
      }
      i++;
      args.add(b.toString());
    }
    if (args.isNotEmpty && args.first.isEmpty) args.removeAt(0);
    if (args.isNotEmpty) steps.add(args);
  }
  return steps;
}

// ── The editor's backend over the add-on ────────────────────────────────

/// [CompilerBackend] on the Compiler add-on: the same flags as the desktop
/// wasi-sdk build, with the XPRS headers from the add-on's /usr/xprs.
class AddonCompilerBackend implements CompilerBackend {
  const AddonCompilerBackend();

  @override
  String get name => 'compiler-addon';

  /// Unknown until a build looks (the lookup is async); the build itself
  /// says plainly when the add-on is missing.
  @override
  bool get isAvailable => true;

  static const _common = <String>[
    '--target=wasm32-wasip1',
    '-O2',
    '-I/usr/xprs',
    '-Wall',
    '-Wextra',
    '-fno-exceptions',
    '-DNDEBUG',
    '-nostartfiles',
    '-Wl,--no-entry',
    '-Wl,--strip-all',
  ];

  /// A plain scratch folder for one build. Not the profile's storage: an
  /// encrypted profile keeps a wapp's data inside its store, where the
  /// compiler, reading files by path, finds nothing (measured on a phone:
  /// clang exited 1 on a /work it saw empty). A wapp's source is public
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
      final b = await AddonClang.instance.build(
        workDir: dir.path,
        flags: [
          ..._common,
          '-Werror',
          '-Wl,--export=module_init',
          '-Wl,--export=module_tick',
          '-Wl,--export=module_handle_event',
          '-Wl,--export=module_destroy',
          '-Wl,--export=module_tick_interval_ms',
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
      final names = <String>[];
      for (var i = 0; i < testSources.length; i++) {
        final n = 'test_$i.c';
        await File(testSources[i]).copy('${dir.path}/$n');
        names.add(n);
      }
      final b = await AddonClang.instance.build(
        workDir: dir.path,
        flags: [
          ..._common,
          '-I/usr/xprs/sdk',
          '-DWAPP_TESTING',
          '-Wl,--export=module_run_tests',
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
          error: b.code == -1 ? b.log : 'clang exited with ${b.code}',
        );
}
