// What the editor asks of an installed wapp, by capability and never by
// name (architecture.md, no-wapp-special-case-in-host): any wapp may provide
// it, the Compiler add-on is just the first that does.
//
//   wapp.edit   a screen that edits a wapp, opened on it; it is told which
//               with {"type":"host.edit_target","dir":...}
//
// Building is not a capability: the app bundles its compiler
// (wapp_compiler_backend_io.dart).
//
// Providers come from the launcher's scan of the installed wapps
// (FunctionalityRegistry), so nothing here reads the disk.

import '../launcher/launcher.dart' show WappManifest;
import '../wapp/functionality_registry.dart';

const wappEditFunctionality = 'wapp.edit';

/// The first installed wapp providing [functionality], or null.
WappManifest? provider(String functionality) {
  for (final m in FunctionalityRegistry.instance.providersFor(functionality)) {
    if (m.dirPath.isNotEmpty) return m;
  }
  return null;
}
