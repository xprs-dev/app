/*
 * The bundled C compiler (assets/compiler), run by the app's own WASM
 * runtime as a phone runs it: a wapp built and instantiated, a compile
 * error reported, and a wapp's test suite built with its
 * `#include "../main.c"` resolved.
 *
 * Needs the runtime's native library, so it is skipped without it:
 *
 *   WASM_RUN_DART_DYNAMIC_LIBRARY=build/linux/arm64/release/bundle/lib/libwasm_run_dart.so \
 *   flutter test test/bundled_compiler_test.dart
 *
 * The wapp sources come from the apps checkout beside this repo (../apps).
 */

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wasm_run/wasm_run.dart';
import 'package:xprs/editor/wapp_compiler_backend_io.dart';
import 'package:xprs_core/src/profile/storage_paths.dart'
    show wappPackageStorage;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const apps = '../apps';
  final ready =
      Platform.environment['WASM_RUN_DART_DYNAMIC_LIBRARY'] != null &&
      File('$apps/tasks/main.c').existsSync();
  const skip = 'needs WASM_RUN_DART_DYNAMIC_LIBRARY and ../apps';
  test('builds a wapp the runtime loads, with its exports', () async {
    final work = await Directory.systemTemp.createTemp('cc-test-');
    addTearDown(() => work.delete(recursive: true));
    final res = await const BundledCompilerBackend().compile(
      source: await File('$apps/tasks/main.c').readAsString(),
      pkg: wappPackageStorage(work.path),
      workStorage: wappPackageStorage(work.path),
    );
    expect(res.ok, isTrue, reason: '${res.error}\n${res.stderr}');
    final module = await compileWasmModule(res.wasmBytes!);
    final exports = module.getExports().map((e) => e.name).toSet();
    expect(exports, containsAll(['module_init', 'module_handle_event']));
    expect(
      module.getImports().map((i) => '${i.module}.${i.name}'),
      contains('hal.log'),
      reason: 'hal_log imports as hal.log, not the C library log()',
    );
  }, skip: ready ? false : skip);

  test('a compile error comes back with its message', () async {
    final work = await Directory.systemTemp.createTemp('cc-test-');
    addTearDown(() => work.delete(recursive: true));
    final res = await const BundledCompilerBackend().compile(
      source: 'void module_init(void) { undefined_thing(); }\n',
      pkg: wappPackageStorage(work.path),
      workStorage: wappPackageStorage(work.path),
    );
    expect(res.ok, isFalse);
    expect(res.stderr, contains('undefined_thing'));
  }, skip: ready ? false : skip);

  test('builds a test suite that includes the wapp', () async {
    final work = await Directory.systemTemp.createTemp('cc-test-');
    addTearDown(() => work.delete(recursive: true));
    final res = await const BundledCompilerBackend().compileTests(
      testSources: ['$apps/mail/tests/test_mail.c'],
      workStorage: wappPackageStorage(work.path),
    );
    expect(res.ok, isTrue, reason: '${res.error}\n${res.stderr}');
    final module = await compileWasmModule(res.wasmBytes!);
    expect(
      module.getExports().map((e) => e.name),
      contains('module_run_tests'),
    );
  }, skip: ready ? false : skip);
}
