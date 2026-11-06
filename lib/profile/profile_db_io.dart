/*
 * Native opener for profile databases (docs/plan-encrypted-storage.md,
 * Phase 2). The keyring and path mapping live in profile_db_common.dart.
 *
 * Every database that lives under a profile folder MUST be opened through
 * [openProfileDb]. Each is a zxdb file (XDb, package:reticulum; pure Dart,
 * no native library). For plain profiles it is opened as it is. For
 * encrypted profiles (a `keyslot.json` exists in the profile root) its
 * password is the per-database key derived from the profile master key
 * (AES-256 in zxdb); a locked profile throws [ProfileLockedException].
 */

import 'package:reticulum/reticulum.dart';

import 'profile_db_common.dart';

export 'profile_db_common.dart';

/// Native: nothing to load ahead of time.
Future<void> initProfileDb() async {}

/// Open a database that is deliberately NOT keyed even inside an encrypted
/// profile (mailbox spools, gossip visit tables).
XDb openPlainDb(String absPath) => xdbOpenFile(absPath);

/// A database in memory.
XDb openMemoryDb() => xdbOpenMemory();

/// Open a database that (possibly) lives inside a profile folder.
///
/// - `:memory:`: a database in memory.
/// - Plain profile / non-profile path: opened as it is.
/// - Encrypted profile, unlocked: opened with its derived password.
/// - Encrypted profile, locked: throws [ProfileLockedException].
/// - Wrong key / not a database: throws [XDbException].
XDb openProfileDb(String absPath) {
  if (absPath == ':memory:') return xdbOpenMemory();
  return xdbOpenFile(absPath, password: _password(absPath));
}

/// The password of the database at [absPath]: null outside an encrypted
/// profile, the derived per-database key inside one ([profileDbKeyHex] is
/// the same for a worker isolate, without the locked-profile check).
String? _password(String absPath) {
  final loc = locateProfileDb(absPath);
  if (loc == null ||
      !ProfileKeyring.instance.isEncryptedProfile(loc.profileId)) {
    return null;
  }
  final keys = ProfileKeyring.instance.keysFor(loc.profileId);
  if (keys == null) throw ProfileLockedException(loc.profileId, absPath);
  return keys.dbKeyHex(loc.relPath);
}
