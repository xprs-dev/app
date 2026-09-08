/*
 * Central SQLite opener for profile databases + the in-memory keyring of
 * unlocked profiles (docs/plan-encrypted-storage.md, Phase 2).
 *
 * One import, two implementations: SQLCipher over FFI on desktop and mobile
 * (profile_db_io.dart), sqlite3.wasm over IndexedDB in a browser
 * (profile_db_web.dart). Both expose the same names -- openProfileDb,
 * openPlainDb, openMemoryDb, initProfileDb, ensureSqlCipherLoaded,
 * engineSqliteLibrary -- plus everything in profile_db_common.dart. Every
 * handle is a `CommonDatabase` (package:sqlite3/common.dart); nothing outside
 * profile_db_io.dart names the FFI `Database`, because that import is what
 * would break the web build.
 */

export 'profile_db_web.dart' if (dart.library.io) 'profile_db_io.dart';
