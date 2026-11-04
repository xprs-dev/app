/*
 * Point package:sqlite3 at the library this app ships, before the first
 * database opens: SQLCipher under its own name on Android. Native only; the
 * web build has no FFI, so its half does nothing.
 */
export 'sqlite_prepare_web.dart' if (dart.library.io) 'sqlite_prepare_io.dart';
