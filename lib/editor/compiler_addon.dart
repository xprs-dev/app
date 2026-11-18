// The Compiler add-on (`tools.xprs.compiler`): an ordinary wapp, installed
// and shared like any other and never part of the app, that brings what a
// phone lacks to build a wapp (clang and wasm-ld compiled to WASI, with the C
// library and the XPRS hal headers) and the AI that edits wapps.
//
// Package layout the host relies on:
//   media/llvm.wasm   YoWASP's LLVM multi-call module (clang, wasm-ld),
//                     WASI preview 1
//   media/usr/        its resources (include/, lib/, share/) plus the XPRS
//                     headers in usr/xprs/ (xprs_wasm_hal.h, ...)

import 'package:xprs_core/src/profile/storage_paths.dart';

const compilerAddonId = 'tools.xprs.compiler';

/// The installed add-on's package directory (absolute), or null.
Future<String?> compilerAddonDir() async {
  final installed = installedAppsStorage();
  if (!await installed.directoryExists('')) return null;
  for (final e in await installed.listDirectory('')) {
    if (!e.isDirectory) continue;
    final abs = installed.getAbsolutePath(e.path);
    final m = await wappPackageStorage(abs).readJson('manifest.json');
    if (m?['id'] == compilerAddonId) return abs;
  }
  return null;
}
