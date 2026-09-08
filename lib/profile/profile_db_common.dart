/*
 * The platform-free half of the profile database layer: the in-memory keyring
 * of unlocked profiles and the path -> (profile, relative path) mapping that
 * every per-database key derivation is built on. Shared verbatim by the native
 * opener (profile_db_io.dart, SQLCipher over FFI) and the web opener
 * (profile_db_web.dart, sqlite3.wasm over IndexedDB).
 */

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../platform/fs.dart';
import 'profile_crypto.dart';
import 'storage_paths.dart';

/// Test seam: overrides the storage root used to map database paths to
/// profiles (normally `xprsRootStorage().basePath`).
@visibleForTesting
String? profileDbRootOverride;

/// Storage root used for profile-path mapping (override-aware; normally
/// `xprsRootStorage().basePath`).
String profileStorageRoot() =>
    profileDbRootOverride ?? xprsRootStorage().basePath;

/// Thrown when a database inside an encrypted profile is opened before the
/// profile has been unlocked.
class ProfileLockedException implements Exception {
  final String profileId;
  final String path;
  const ProfileLockedException(this.profileId, this.path);
  @override
  String toString() =>
      'ProfileLockedException: profile $profileId is locked (wanted $path)';
}

/// File name that marks a profile as encrypted (written at enable time,
/// holds the wrapped master key — see ProfileKeyslot).
const String keyslotFileName = 'keyslot.json';

/// In-memory keyring of unlocked profiles. UI (unlock page) or the
/// remember-key cache put keys in; `openProfileDb` and the encrypted
/// ProfileStorage backend read them out.
class ProfileKeyring {
  ProfileKeyring._();
  static final ProfileKeyring instance = ProfileKeyring._();

  final Map<String, UnlockedProfileKeys> _unlocked = {};

  /// Listeners fired (fire-and-forget) when a profile locks, so holders of
  /// derived resources (open profile.ear archives) can close them.
  final List<Future<void> Function(String profileId)> onLock = [];

  /// Listeners fired (fire-and-forget) right after a profile unlocks. The
  /// encrypted storage backend uses this to pre-open profile.ear so the
  /// sync (WASM HAL) paths find it ready.
  final List<Future<void> Function(String profileId)> onUnlock = [];

  bool isUnlocked(String profileId) => _unlocked.containsKey(profileId);

  UnlockedProfileKeys? keysFor(String profileId) => _unlocked[profileId];

  void putKeys(String profileId, UnlockedProfileKeys keys) {
    _unlocked[profileId]?.dispose();
    _unlocked[profileId] = keys;
    for (final listener in onUnlock) {
      unawaited(listener(profileId));
    }
  }

  /// Drop a profile's keys (zeroing the master key). Fires [onLock] so the
  /// encrypted storage backend closes its archive; database handles opened
  /// via `openProfileDb` must be closed by their owners.
  void lock(String profileId) {
    final keys = _unlocked.remove(profileId);
    if (keys == null) return;
    for (final listener in onLock) {
      unawaited(listener(profileId));
    }
    keys.dispose();
  }

  void lockAll() {
    for (final id in _unlocked.keys.toList()) {
      lock(id);
    }
  }

  /// Whether the profile with [profileId] has encryption enabled on disk.
  bool isEncryptedProfile(String profileId) =>
      fs.file(_keyslotPath(profileId)).existsSync();

  String _keyslotPath(String profileId) =>
      '${profileStorageRoot()}/devices/$profileId/$keyslotFileName';
}

/// SQLCipher key (raw hex) for the database at [absPath], or null when it is
/// not inside an encrypted profile. For isolates that cannot reach the
/// keyring; on the main isolate, `openProfileDb` does this itself.
String? profileDbKeyHex(String absPath) {
  final loc = locateProfileDb(absPath);
  if (loc == null) return null;
  if (!ProfileKeyring.instance.isEncryptedProfile(loc.profileId)) return null;
  return ProfileKeyring.instance.keysFor(loc.profileId)?.dbKeyHex(loc.relPath);
}

/// Result of mapping an absolute path into the profile layout.
class ProfileDbLocation {
  final String profileId;

  /// Forward-slash path relative to `devices/<id>/`, e.g. `data/mesh.sqlite3`.
  /// This exact string feeds the per-DB key derivation — treat as stable API.
  final String relPath;

  const ProfileDbLocation(this.profileId, this.relPath);
}

/// Map [absPath] to (profileId, profile-relative path), or null when the
/// path is not inside `devices/<id>/` (e.g. the user pointed the wapp data
/// dir somewhere else via preferences — those databases stay plain; the
/// plan documents this limitation).
ProfileDbLocation? locateProfileDb(String absPath) {
  final root = profileStorageRoot().replaceAll('\\', '/');
  final norm = absPath.replaceAll('\\', '/');
  final prefix = '$root/devices/';
  if (!norm.startsWith(prefix)) return null;
  final rest = norm.substring(prefix.length);
  final slash = rest.indexOf('/');
  if (slash <= 0 || slash == rest.length - 1) return null;
  final profileId = rest.substring(0, slash);
  final relPath = rest.substring(slash + 1);
  return ProfileDbLocation(profileId, relPath);
}
