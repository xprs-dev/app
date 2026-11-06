/*
 * Central opener for profile databases + the in-memory keyring of unlocked
 * profiles (docs/plan-encrypted-storage.md, Phase 2).
 *
 * One import, two implementations: zxdb files on desktop and mobile
 * (profile_db_io.dart), the browser's (profile_db_web.dart). Both expose the
 * same names -- openProfileDb, openPlainDb, openMemoryDb, initProfileDb --
 * plus everything in profile_db_common.dart. Every
 * handle is an XDb (package:reticulum).
 */

export 'profile_db_web.dart' if (dart.library.io) 'profile_db_io.dart';
