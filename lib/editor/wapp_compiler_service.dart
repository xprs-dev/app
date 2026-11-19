/*
 * WappCompilerService — compiles a C source string into a wapp
 * `app.wasm` byte array.
 *
 * A thin singleton in front of a `CompilerBackend`. On every native
 * platform that is the compiler the app bundles (xcc compiled to WASI,
 * wapp_compiler_backend_io.dart), so a phone and a desktop build alike
 * with nothing installed; the web build has none.
 *
 * Wapps should always call through `WappCompilerService.instance`.
 */

import 'dart:async';
import 'dart:typed_data';

import '../models/monitored_task.dart';
import '../profile/profile_storage.dart';
import '../services/task_monitor_service.dart';
import 'wapp_compiler_backend_web.dart'
    if (dart.library.io) 'wapp_compiler_backend_io.dart';

/// Outcome of a single compile run.
class CompileResult {
  /// True iff the compiler produced non-empty wasm bytes and exited 0.
  final bool ok;

  /// Compiled wapp bytes on success, null on failure.
  final Uint8List? wasmBytes;

  /// Captured stdout / stderr. Shown in the App Creator log view.
  final String stdout;
  final String stderr;
  final int exitCode;
  final int durationMs;

  /// Short human-readable error message on failure. Safe to put in a
  /// notification title.
  final String? error;

  const CompileResult({
    required this.ok,
    this.wasmBytes,
    this.stdout = '',
    this.stderr = '',
    this.exitCode = 0,
    this.durationMs = 0,
    this.error,
  });

  factory CompileResult.failure(
    String message, {
    String stdout = '',
    String stderr = '',
    int exitCode = 1,
    int durationMs = 0,
  }) => CompileResult(
    ok: false,
    stdout: stdout,
    stderr: stderr,
    exitCode: exitCode,
    durationMs: durationMs,
    error: message,
  );
}

/// Abstract compiler backend. Every new compiler path (native,
/// in-wasm, remote) plugs in here.
abstract class CompilerBackend {
  String get name;

  /// True iff this backend can run on the current host right now.
  /// Checked before every compile so the service can pick the best
  /// available backend without the caller knowing.
  bool get isAvailable;

  /// Run the compiler. [pkg] is the calling wapp's package storage
  /// (so the backend can read a bundled `media/compilers/cpp.wasm`
  /// or similar). [workStorage] is the wapp's per-user work folder,
  /// used for temp files (`compile-tmp/`) and the cached output.
  Future<CompileResult> compile({
    required String source,
    required ProfileStorage pkg,
    required ProfileStorage workStorage,
  });

  /// Build a wapp's test suite into a `tests.wasm` exporting
  /// `module_run_tests`. [testSources] are absolute paths to the
  /// wapp's `tests/*.c` (each typically `#include`s the lib under
  /// test, so they're passed at their real location). The SDK runner
  /// (`wapp_test.c`) is linked in automatically.
  Future<CompileResult> compileTests({
    required List<String> testSources,
    required ProfileStorage workStorage,
  });
}

// ── Service singleton ───────────────────────────────────────────────

class WappCompilerService {
  WappCompilerService._();
  static final WappCompilerService instance = WappCompilerService._();

  /// The active compiler backend, resolved by a conditional import: the
  /// bundled compiler on native platforms, a "not supported" stub on web.
  final CompilerBackend backend = makeCompilerBackend();

  /// Run the compiler. Wraps the whole call in a `MonitoredTask` so
  /// it appears in the tasks wapp alongside wapp tick loops. Never
  /// throws — failures come back as `CompileResult.failure`.
  Future<CompileResult> compile({
    required String source,
    required ProfileStorage pkg,
    required ProfileStorage workStorage,
  }) async {
    final monitor = TaskMonitorService.instance;
    const taskId = 'compiler.compile';
    // Re-register so duration numbers reset between runs.
    monitor.unregister(taskId);
    monitor.register(
      MonitoredTask(
        id: taskId,
        name: 'Compile wapp source',
        description: 'Backend: ${backend.name}',
        serviceName: 'compiler',
        priority: TaskPriority.normal,
        type: TaskType.oneshot,
      ),
    );
    monitor.reportStart(taskId);
    try {
      final result = await backend.compile(
        source: source,
        pkg: pkg,
        workStorage: workStorage,
      );
      if (result.ok) {
        monitor.reportSuccess(taskId);
      } else {
        monitor.reportFailure(taskId, result.error ?? 'compile failed');
      }
      return result;
    } catch (e) {
      monitor.reportFailure(taskId, e);
      return CompileResult.failure(e.toString());
    }
  }

  /// Build a wapp's test suite (see [CompilerBackend.compileTests]).
  Future<CompileResult> compileTests({
    required List<String> testSources,
    required ProfileStorage workStorage,
  }) async {
    final monitor = TaskMonitorService.instance;
    const taskId = 'compiler.tests';
    monitor.unregister(taskId);
    monitor.register(
      MonitoredTask(
        id: taskId,
        name: 'Compile wapp tests',
        description: 'Backend: ${backend.name}',
        serviceName: 'compiler',
        priority: TaskPriority.normal,
        type: TaskType.oneshot,
      ),
    );
    monitor.reportStart(taskId);
    try {
      final result = await backend.compileTests(
        testSources: testSources,
        workStorage: workStorage,
      );
      if (result.ok) {
        monitor.reportSuccess(taskId);
      } else {
        monitor.reportFailure(taskId, result.error ?? 'tests compile failed');
      }
      return result;
    } catch (e) {
      monitor.reportFailure(taskId, e);
      return CompileResult.failure(e.toString());
    }
  }
}
