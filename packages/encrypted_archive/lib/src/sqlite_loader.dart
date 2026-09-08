/// Platform-aware SQLite opener.
///
/// The archive is a SQLite file, and the library that opens it differs per
/// target: the FFI binding with a bundled native library on the Dart VM, the
/// FFI binding with the host's plugin-provided library in a Flutter app, and
/// sqlite3.wasm over IndexedDB in a browser -- which the package cannot load
/// on its own (the wasm is fetched asynchronously by the host), so the host
/// injects [SQLiteLoader.override] before the first open. Every handle is
/// typed as [CommonDatabase] so callers never see the FFI type.
library;

import 'package:sqlite3/common.dart';

import 'sqlite_loader_pure.dart'
    if (dart.library.js_interop) 'sqlite_loader_stub.dart'
    if (dart.library.ui) 'sqlite_loader_flutter.dart' as platform;

class SQLiteLoader {
  SQLiteLoader._();

  /// Host-supplied opener that replaces the platform default. Required on
  /// web; optional elsewhere (an encrypting host uses it to apply keys).
  static CommonDatabase Function(String dbPath)? override;

  /// Open or create a database at [dbPath].
  static CommonDatabase openDatabase(String dbPath) {
    final o = override;
    if (o != null) return o(dbPath);
    return platform.openDatabase(dbPath);
  }

  /// Open an in-memory database.
  static CommonDatabase openInMemory() => platform.openInMemory();
}
