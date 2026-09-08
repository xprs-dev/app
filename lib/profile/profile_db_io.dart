/*
 * Native SQLite opener for profile databases (docs/plan-encrypted-storage.md,
 * Phase 2). The keyring and path mapping live in profile_db_common.dart.
 *
 * Every `sqlite3.open()` on a database that lives under a profile folder
 * MUST go through [openProfileDb]. For plain profiles it behaves exactly
 * like `sqlite3.open`. For encrypted profiles (a `keyslot.json` exists in
 * the profile root) it applies the per-database SQLCipher key derived from
 * the profile master key, or throws [ProfileLockedException] when the
 * profile has not been unlocked yet.
 *
 * The native library is SQLCipher on every platform
 * (sqlcipher_flutter_libs); it opens plain SQLite databases identically
 * when no key is set, so unencrypted profiles are unaffected.
 *
 * The only file in lib/ that imports the FFI half of package:sqlite3 or the
 * SQLCipher plugin; the web build never compiles it.
 */

import 'dart:io';

import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';
import 'package:sqlite3/common.dart';
import 'package:sqlite3/open.dart';
import 'package:sqlite3/sqlite3.dart';

import 'profile_db_common.dart';

export 'profile_db_common.dart';

/// Native: nothing to load ahead of time; the FFI binding resolves the
/// library on first open.
Future<void> initProfileDb() async {}

bool _sqlcipherLoaded = false;

/// Make package:sqlite3 resolve to the bundled SQLCipher library. Safe to
/// call repeatedly; must run before the first database open on Android
/// (package:sqlite3 caches the loaded library on first use — since every
/// profile DB open goes through [openProfileDb], that holds).
void ensureSqlCipherLoaded() {
  if (_sqlcipherLoaded) return;
  if (Platform.isAndroid) {
    open.overrideFor(OperatingSystem.android, openCipherOnAndroid);
  }
  // Desktop + iOS/macOS: sqlcipher_flutter_libs bundles the library under
  // the default resolution names, no override needed.
  _sqlcipherLoaded = true;
}

/// The native SQLite library a BACKGROUND ISOLATE must load before it opens
/// a database, or null when the platform default is right.
///
/// package:sqlite3's loader override lives per-isolate: [ensureSqlCipherLoaded]
/// only fixes the isolate it runs on. Any isolate that opens SQLite (the NOSTR
/// engine) has to be told the same thing, or it looks for a plain libsqlite3.so
/// that this app does not ship — and dies. Pass this into the spawn message.
String? engineSqliteLibrary() => Platform.isAndroid ? 'libsqlcipher.so' : null;

/// Wait, briefly, for a lock instead of throwing the instant one is met.
///
/// SQLite defaults to a zero busy timeout, so a second connection opening a
/// file the first is still checkpointing throws SQLITE_BUSY immediately. Two
/// engines share every profile database over a session -- a wapp's page and
/// its headless twin, the mesh service and its stores -- and the handoff
/// between them is a few milliseconds of overlap. Without this a message that
/// arrived during that overlap was written to a store that never opened its
/// database, and vanished while its notification fired. Four seconds is far
/// longer than any checkpoint and still bounded, so a genuinely stuck lock
/// still surfaces rather than hanging.
void _setBusyTimeout(CommonDatabase db) {
  try {
    db.execute('PRAGMA busy_timeout = 4000;');
  } catch (_) {
    // A pragma that will not set is not a reason to fail the open.
  }
}

/// Open a database that is deliberately NOT keyed even inside an encrypted
/// profile (mailbox spools, gossip visit tables: created plain before
/// encryption existed and left plain so existing files keep opening). Same
/// busy timeout as [openProfileDb].
CommonDatabase openPlainDb(String absPath) {
  ensureSqlCipherLoaded();
  final db = sqlite3.open(absPath);
  _setBusyTimeout(db);
  return db;
}

/// In-memory database on the native binding.
CommonDatabase openMemoryDb() {
  ensureSqlCipherLoaded();
  return sqlite3.openInMemory();
}

/// Open a SQLite database that (possibly) lives inside a profile folder.
///
/// - Plain profile / non-profile path: behaves exactly like `sqlite3.open`.
/// - Encrypted profile, unlocked: opens with the derived SQLCipher key.
/// - Encrypted profile, locked: throws [ProfileLockedException].
/// - Wrong key / corrupt file: throws [SqliteException] (NOTADB).
CommonDatabase openProfileDb(String absPath) {
  ensureSqlCipherLoaded();

  final loc = locateProfileDb(absPath);
  if (loc == null || !ProfileKeyring.instance.isEncryptedProfile(loc.profileId)) {
    final db = sqlite3.open(absPath);
    _setBusyTimeout(db);
    return db;
  }

  final keys = ProfileKeyring.instance.keysFor(loc.profileId);
  if (keys == null) {
    throw ProfileLockedException(loc.profileId, absPath);
  }

  final db = sqlite3.open(absPath);
  try {
    _setBusyTimeout(db);
    db.execute('PRAGMA key = "x\'${keys.dbKeyHex(loc.relPath)}\'";');

    // If the plain sqlite3 library got loaded instead of SQLCipher the key
    // pragma silently no-ops and we would write PLAINTEXT — fail loud.
    final cipherVersion = db.select('PRAGMA cipher_version;');
    if (cipherVersion.isEmpty) {
      throw StateError(
        'SQLCipher not loaded (cipher_version empty) — refusing to open '
        'encrypted profile database $absPath without encryption',
      );
    }

    // Force key verification now (wrong key surfaces here as NOTADB
    // instead of at some later random query).
    db.select('SELECT count(*) FROM sqlite_master;');
    return db;
  } catch (_) {
    db.dispose();
    rethrow;
  }
}
