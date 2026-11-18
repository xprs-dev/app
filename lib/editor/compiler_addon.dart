// What the editor asks of an installed wapp, by capability and never by
// name (architecture.md, no-wapp-special-case-in-host): any wapp may provide
// these, the Compiler add-on is just the first that does.
//
//   wapp.build  a toolchain the host runs to build a wapp where there is no
//               wasi-sdk (a phone). Package layout the host relies on:
//                 media/llvm.wasm   clang + wasm-ld as one WASI preview 1
//                                   module, chosen by argv[0]
//                 media/usr/        its headers and libraries, plus the XPRS
//                                   headers in usr/xprs/ and the test runner
//                                   in usr/xprs/sdk/
//   wapp.edit   a screen that edits a wapp, opened on it; it is told which
//               with {"type":"host.edit_target","dir":...}
//
// Providers come from the launcher's scan of the installed wapps
// (FunctionalityRegistry), so nothing here reads the disk.

import '../launcher/launcher.dart' show WappManifest;
import '../wapp/functionality_registry.dart';

const wappBuildFunctionality = 'wapp.build';
const wappEditFunctionality = 'wapp.edit';

/// The first installed wapp providing [functionality], or null.
WappManifest? provider(String functionality) {
  for (final m in FunctionalityRegistry.instance.providersFor(functionality)) {
    if (m.dirPath.isNotEmpty) return m;
  }
  return null;
}

/// Its package directory (absolute), or null.
String? providerDir(String functionality) => provider(functionality)?.dirPath;
