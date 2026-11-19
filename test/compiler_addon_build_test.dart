/*
 * The Compiler add-on's toolchain, run by the app's own WASM runtime the way
 * a phone runs it: a wapp built and instantiated, and a wapp's test suite
 * built with its `#include "../main.c"` resolved.
 *
 * Needs the add-on's toolchain (apps/compiler: `make`, which fetches and
 * builds it into media/) and the runtime's native library:
 *
 *   XPRS_COMPILER_ADDON=../apps/compiler \
 *   WASM_RUN_DART_DYNAMIC_LIBRARY=build/linux/arm64/release/bundle/lib/libwasm_run_dart.so \
 *   flutter test test/compiler_addon_build_test.dart
 *
 * Skipped otherwise.
 */

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wasm_run/wasm_run.dart';
import 'package:xprs/editor/compiler_addon.dart';
import 'package:xprs/editor/wapp_compiler_backend_addon_io.dart';
import 'package:xprs/launcher/launcher.dart' show WappManifest;
import 'package:xprs/wapp/functionality_registry.dart';
import 'package:xprs_core/src/profile/storage_paths.dart'
    show wappPackageStorage;

void main() {
  final addon = Platform.environment['XPRS_COMPILER_ADDON'];
  final ready =
      addon != null &&
      File('$addon/media/cc.wasm').existsSync() &&
      Platform.environment['WASM_RUN_DART_DYNAMIC_LIBRARY'] != null;
  final apps = addon == null ? '' : Directory(addon).parent.path;

  setUpAll(() {
    if (!ready) return;
    FunctionalityRegistry.instance.clear();
    FunctionalityRegistry.instance.register(
      WappManifest.fromJson({
        'id': 'tools.xprs.compiler',
        'title': 'Compiler',
        'provides': {
          'functionalities': [wappBuildFunctionality],
        },
      }, Directory(addon).absolute.path),
    );
  });

  test('builds a wapp the runtime loads, with its exports', () async {
    final work = await Directory.systemTemp.createTemp('addon-test-');
    addTearDown(() => work.delete(recursive: true));
    final res = await const AddonCompilerBackend().compile(
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
  }, skip: ready ? false : 'no Compiler add-on toolchain');

  test('a compile error comes back with its message', () async {
    final work = await Directory.systemTemp.createTemp('addon-test-');
    addTearDown(() => work.delete(recursive: true));
    final res = await const AddonCompilerBackend().compile(
      source: 'void module_init(void) { undefined_thing(); }\n',
      pkg: wappPackageStorage(work.path),
      workStorage: wappPackageStorage(work.path),
    );
    expect(res.ok, isFalse);
    expect(res.stderr, contains('undefined_thing'));
  }, skip: ready ? false : 'no Compiler add-on toolchain');

  test('builds a test suite that includes the wapp', () async {
    final work = await Directory.systemTemp.createTemp('addon-test-');
    addTearDown(() => work.delete(recursive: true));
    final res = await const AddonCompilerBackend().compileTests(
      testSources: ['$apps/mail/tests/test_mail.c'],
      workStorage: wappPackageStorage(work.path),
    );
    expect(res.ok, isTrue, reason: '${res.error}\n${res.stderr}');
    final module = await compileWasmModule(res.wasmBytes!);
    expect(
      module.getExports().map((e) => e.name),
      contains('module_run_tests'),
    );
  }, skip: ready ? false : 'no Compiler add-on toolchain');
}
