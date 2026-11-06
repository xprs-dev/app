/*
 * Web opener for profile databases. The keyring and path mapping live in
 * profile_db_common.dart; the public surface matches profile_db_io.dart
 * symbol for symbol so callers do not know which they got.
 *
 * Every database is an XDb (zxdb, package:reticulum) in MEMORY: zxdb's file
 * store reads and writes through dart:io, and its browser engine opens
 * archives read only, so there is no writable database file in a browser
 * yet. A page's stores therefore last as long as the tab (docs/web.md). An
 * encrypted profile is refused, never opened unprotected.
 */

import 'package:reticulum/reticulum.dart';

import 'profile_db_common.dart';

export 'profile_db_common.dart';

/// Nothing to load ahead of time.
Future<void> initProfileDb() async {}

/// A database in memory (see the file comment).
XDb openPlainDb(String absPath) => xdbOpenMemory();

/// A database in memory.
XDb openMemoryDb() => xdbOpenMemory();

/// Open a database that (possibly) lives inside a profile folder.
///
/// - Plain profile / non-profile path: a database in memory.
/// - Encrypted profile: throws [UnsupportedError]. Never an unprotected
///   open of something the user asked to be encrypted.
XDb openProfileDb(String absPath) {
  final loc = locateProfileDb(absPath);
  if (loc != null &&
      ProfileKeyring.instance.isEncryptedProfile(loc.profileId)) {
    throw UnsupportedError(
        'encrypted profiles are not available on web -- refusing to open '
        '$absPath');
  }
  return xdbOpenMemory();
}
