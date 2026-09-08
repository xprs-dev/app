/*
 * Web SQLite opener for profile databases: the same package:sqlite3, its
 * browser half -- sqlite3.wasm driven through a virtual filesystem that
 * persists into IndexedDB. The keyring and path mapping live in
 * profile_db_common.dart; the public surface here matches profile_db_io.dart
 * symbol for symbol so callers do not know which they got.
 *
 * Differences that are the browser's, not ours:
 *
 * - The engine loads asynchronously. [initProfileDb] fetches `sqlite3.wasm`
 *   (served from web/, pinned to the pub version of package:sqlite3) and
 *   opens the IndexedDB-backed VFS; storage_paths.initStorageRoot awaits it
 *   before any store is constructed. Opening a database before that is a
 *   StateError, never a silent in-memory database.
 * - Every open is plain. The stock wasm build has no SQLCipher, and the
 *   multi-cipher build that exists from sqlite3 2.7 uses a different on-disk
 *   format anyway, so an ENCRYPTED profile is refused with UnsupportedError
 *   rather than opened as plaintext (docs/web.md).
 * - The VFS is single-tab: a second tab writing the same IndexedDB database
 *   corrupts it. The database name is fixed so a second XPRS tab shares the
 *   same store; refusing the second tab is the host's job (docs/web.md).
 */

import 'package:sqlite3/common.dart';
import 'package:sqlite3/wasm.dart';

import 'profile_db_common.dart';

export 'profile_db_common.dart';

/// IndexedDB database that holds every SQLite file of this origin.
const String webSqliteStoreName = 'xprs-sqlite';

WasmSqlite3? _sqlite;
IndexedDbFileSystem? _vfs;

/// Load sqlite3.wasm and open the IndexedDB VFS. Idempotent.
Future<void> initProfileDb({Uri? wasm}) async {
  if (_sqlite != null) return;
  final engine = await WasmSqlite3.loadFromUrl(
      wasm ?? Uri.parse('sqlite3.wasm'));
  final vfs = await IndexedDbFileSystem.open(dbName: webSqliteStoreName);
  engine.registerVirtualFileSystem(vfs, makeDefault: true);
  _sqlite = engine;
  _vfs = vfs;
}

WasmSqlite3 _engine() {
  final s = _sqlite;
  if (s == null) {
    throw StateError(
        'profile_db: initProfileDb() has not completed -- sqlite3.wasm is '
        'not loaded yet, so no database can be opened');
  }
  return s;
}

/// Flush the VFS's in-memory view to IndexedDB. Call after writes a reload
/// must not lose; the VFS also flushes on its own timer.
Future<void> flushProfileDb() async {
  await _vfs?.flush();
}

/// No native library on web; kept so callers compile unchanged.
void ensureSqlCipherLoaded() {}

/// No isolates on web either; the value is only ever passed to a spawn.
String? engineSqliteLibrary() => null;

/// Open on the wasm engine with the two pragmas the browser VFS needs.
///
/// `temp_store = MEMORY`: SQLite otherwise opens its temporary files
/// (statement journals, the scratch database an ALTER TABLE uses) through
/// the VFS with a NULL name, and sqlite3 2.4.5's IndexedDB VFS dereferences
/// that name -- `Cannot read properties of null (reading 'toString')` from
/// inside the wasm import table. In memory, no file, no name.
///
/// `journal_mode = MEMORY`: there is no shared memory for WAL in a VFS over
/// IndexedDB, and a rollback journal is another file per write; a single-tab
/// store with the whole database in the VFS's memory cache gains nothing
/// from either.
CommonDatabase _openWeb(String absPath) {
  final db = _engine().open(absPath);
  try {
    db.execute('PRAGMA temp_store = MEMORY;');
    db.execute('PRAGMA journal_mode = MEMORY;');
  } catch (_) {
    db.dispose();
    rethrow;
  }
  return db;
}

/// Plain open on the wasm engine (see the file comment: every open is
/// plain here, this one is plain by contract everywhere).
CommonDatabase openPlainDb(String absPath) => _openWeb(absPath);

/// In-memory database on the wasm engine.
CommonDatabase openMemoryDb() => _engine().openInMemory();

/// Open a database that (possibly) lives inside a profile folder.
///
/// - Plain profile / non-profile path: opens on the IndexedDB VFS.
/// - Encrypted profile: throws [UnsupportedError]. Never a plaintext open of
///   something the user asked to be encrypted.
CommonDatabase openProfileDb(String absPath) {
  final loc = locateProfileDb(absPath);
  if (loc != null && ProfileKeyring.instance.isEncryptedProfile(loc.profileId)) {
    throw UnsupportedError(
        'encrypted profiles are not available on web (no SQLCipher in '
        'sqlite3.wasm) -- refusing to open $absPath');
  }
  return _openWeb(absPath);
}
