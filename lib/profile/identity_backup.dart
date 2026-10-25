/*
 * IdentityBackup — keep the user's identity (the nsec) safe across uninstall.
 *
 * The nsec IS the identity: npub, callsign, and the ability to sign/decrypt all
 * derive from it. It normally lives only in `profiles.json` under the app's
 * private support dir, which Android deletes on uninstall — so a reinstall (or a
 * data wipe) loses the identity forever.
 *
 * This service mirrors the identity-only subset of every profile to a location
 * that SURVIVES uninstall:
 *   - Android: /storage/emulated/0/XPRS/identity-backup.json (public storage,
 *     reachable via MANAGE_EXTERNAL_STORAGE, or READ/WRITE_EXTERNAL_STORAGE
 *     below Android 11 — the same access the disk-folder picker uses).
 *     Android keeps this when the app is removed.
 *   - Desktop: $HOME/.config/xprs/identity-backup.json (deliberately OUTSIDE
 *     ~/.local/share/xprs so wiping app data doesn't take the backup with it).
 *
 * On Android the file sits in shared storage, where any app with all-files
 * access (or legacy storage below Android 11) can read it, so it is ONLY ever
 * written encrypted: AES-256-GCM with a PBKDF2-HMAC-SHA256 key from the user's
 * passphrase. Without a passphrase nothing is written there, and a plaintext
 * file left by an older build is deleted (after it has had its chance to be
 * restored from on the welcome page). On desktop the file sits beside the
 * profile store under the user's own home, so it may stay plaintext when no
 * passphrase is set. We never store the passphrase in the backup: the user
 * must remember it (the device keystore can't help: it is wiped on uninstall
 * too). The key derivation runs on a worker isolate, never the UI isolate.
 *
 * Writes are best-effort and atomic (tmp + rename); failures are logged, never
 * thrown into the caller, so a missing permission never breaks profile saves.
 */

import 'dart:convert';
import 'package:file/file.dart';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show compute;

import '../platform/platform.dart' as platform;
import '../services/android_permissions_service.dart';
import '../services/log_service.dart';
import 'iwi_profile.dart';
import '../platform/fs.dart';
import '../services/i18n/core_i18n.dart';

/// One identity restorable from a backup file.
class RestorableIdentity {
  final String callsign;

  /// The licensed callsign this identity transmitted under, or empty.
  ///
  /// Carried because a restore re-derives everything else from the nsec
  /// (XPRS.md 3: the derived callsign IS a function of the key) but cannot
  /// re-derive this one: an issued callsign has no arithmetic relationship to
  /// any key (XPRS.md 6.4.2). Without it, restoring a backup would silently
  /// put a licensed operator back on the air under an `X1`.
  final String licenceCallsign;

  /// Every issued callsign the identity held (one per jurisdiction), the
  /// active one among them. Empty in a backup written before a profile could
  /// hold several; [licenceCallsign] alone is then the list.
  final List<String> licenceCallsigns;
  final String npub;
  final String nsec;
  final String nickname;
  final int createdAt;
  const RestorableIdentity({
    required this.callsign,
    required this.npub,
    required this.nsec,
    required this.nickname,
    required this.createdAt,
    this.licenceCallsign = '',
    this.licenceCallsigns = const [],
  });

  factory RestorableIdentity.fromJson(Map<String, dynamic> j) => RestorableIdentity(
        callsign: (j['callsign'] as String?) ?? '',
        licenceCallsign: (j['licenceCallsign'] as String?) ?? '',
        licenceCallsigns: [
          for (final c in (j['licenceCallsigns'] as List?) ?? const [])
            if (c is String && c.trim().isNotEmpty) c.trim().toUpperCase(),
        ],
        npub: (j['npub'] as String?) ?? '',
        nsec: (j['nsec'] as String?) ?? '',
        nickname: (j['nickname'] as String?) ?? '',
        createdAt: (j['createdAt'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      );
}

/// Thrown by [IdentityBackup.readBackup] when the file is encrypted and the
/// passphrase is missing or wrong (or the file is corrupt).
class BadPassphrase implements Exception {
  final String message;
  const BadPassphrase(this.message);
  @override
  String toString() => message;
}

class IdentityBackup {
  IdentityBackup._();
  static final IdentityBackup instance = IdentityBackup._();

  static const String _fileName = 'identity-backup.json';
  static const int _kdfIters = 120000;

  bool get _isAndroid => platform.platformName() == 'android';

  /// True where the backup lives in storage other apps can read (Android
  /// shared storage): there it is written only when a passphrase is set.
  bool get requiresPassphrase => _isAndroid;

  /// Directory for the backup, or null when it isn't reachable (e.g. Android
  /// all-files-access not granted yet). Creates it when [create] is true.
  Future<String?> backupDir({bool create = false}) async {
    if (_isAndroid) {
      if (!await AndroidPermissionsService.instance.hasAllFilesAccess()) {
        return null;
      }
      for (final root in const ['/storage/emulated/0', '/sdcard']) {
        if (!await fs.directory(root).exists()) continue;
        final d = fs.directory('$root/XPRS');
        if (await d.exists()) return d.path;
        if (create) {
          try {
            await d.create(recursive: true);
            return d.path;
          } catch (_) {
            return null;
          }
        }
      }
      return null;
    }
    final home = platform.homeDir();
    if (home == null || home.isEmpty) return null;
    final d = fs.directory('$home/.config/xprs');
    if (create && !await d.exists()) {
      try {
        await d.create(recursive: true);
      } catch (_) {
        return null;
      }
    }
    return d.path;
  }

  Future<File?> _file({bool create = false}) async {
    final dir = await backupDir(create: create);
    if (dir == null) return null;
    return fs.file('$dir/$_fileName');
  }

  /// Human-readable path of the backup file (for the UI), or null if unreachable.
  Future<String?> backupPath() async => (await _file())?.path;

  /// True when a backup file exists and is reachable.
  Future<bool> backupExists() async {
    final f = await _file();
    return f != null && await f.exists();
  }

  /// True when the existing backup is passphrase-encrypted.
  Future<bool> isEncrypted() async {
    final f = await _file();
    if (f == null || !await f.exists()) return false;
    try {
      final raw = jsonDecode(await f.readAsString());
      return raw is Map && raw['encrypted'] == true;
    } catch (_) {
      return false;
    }
  }

  /// Mirror the identity subset of [profiles] to the survives-uninstall file.
  /// Best-effort: never throws. A missing permission / unreachable path is a
  /// silent no-op so profile saves are never blocked.
  Future<void> backupAll(List<IwiProfile> profiles,
      {String passphrase = ''}) async {
    try {
      // Locked encrypted profiles carry an empty in-memory nsec; never let
      // them overwrite a good backup entry with an empty key — keep the
      // previous backup entry for those instead.
      final withKey = profiles.where((p) => p.nsec.isNotEmpty).toList();
      final lockedNpubs = profiles
          .where((p) => p.nsec.isEmpty)
          .map((p) => p.npub)
          .toSet();
      if (withKey.isEmpty && lockedNpubs.isEmpty) return;
      if (requiresPassphrase && passphrase.isEmpty) {
        await _removePlaintext();
        return;
      }
      final f = await _file(create: true);
      if (f == null) return;

      final identities = withKey
          .map((p) => {
                'callsign': p.callsign,
                if (p.licenceCallsign.isNotEmpty)
                  'licenceCallsign': p.licenceCallsign,
                if (p.heldLicences.isNotEmpty)
                  'licenceCallsigns': p.heldLicences,
                'npub': p.npub,
                'nsec': p.nsec,
                'nickname': p.nickname,
                'createdAt': p.createdAt,
              })
          .toList();
      if (lockedNpubs.isNotEmpty) {
        try {
          final existing = await readBackup(passphrase: passphrase);
          final have = identities.map((m) => m['npub']).toSet();
          for (final r in existing) {
            if (lockedNpubs.contains(r.npub) && !have.contains(r.npub)) {
              identities.add({
                'callsign': r.callsign,
                if (r.licenceCallsign.isNotEmpty)
                  'licenceCallsign': r.licenceCallsign,
                if (r.licenceCallsigns.isNotEmpty)
                  'licenceCallsigns': r.licenceCallsigns,
                'npub': r.npub,
                'nsec': r.nsec,
                'nickname': r.nickname,
                'createdAt': r.createdAt,
              });
            }
          }
        } catch (_) {
          // unreadable old backup (different passphrase) — keep what we have
        }
      }
      if (identities.isEmpty) return;
      Map<String, dynamic> payload;
      if (passphrase.isNotEmpty) {
        payload = await _encrypt(jsonEncode({'profiles': identities}), passphrase);
      } else {
        payload = {'encrypted': false, 'profiles': identities};
      }
      payload['version'] = 1;
      payload['savedAt'] = DateTime.now().toUtc().toIso8601String();
      final tmp = fs.file('${f.path}.tmp');
      await tmp.writeAsString(jsonEncode(payload), flush: true);
      await tmp.rename(f.path);
    } catch (e) {
      LogService.instance.add('IdentityBackup: backup failed: $e');
    }
  }

  /// Delete a plaintext backup an older build left in shared storage. An
  /// encrypted one is kept: it exposes nothing and may be the user's only copy.
  Future<void> _removePlaintext() async {
    final f = await _file();
    if (f == null || !await f.exists() || await isEncrypted()) return;
    try {
      await f.delete();
      LogService.instance.add('IdentityBackup: removed plaintext backup ${f.path}');
    } catch (e) {
      LogService.instance.add('IdentityBackup: could not remove ${f.path}: $e');
    }
  }

  /// Read the backed-up identities. Returns [] when there is no backup. Throws
  /// [BadPassphrase] when the file is encrypted and [passphrase] is wrong/missing.
  Future<List<RestorableIdentity>> readBackup({String passphrase = ''}) async {
    final f = await _file();
    if (f == null || !await f.exists()) return const [];
    final Object? decoded;
    try {
      decoded = jsonDecode(await f.readAsString());
    } catch (_) {
      throw BadPassphrase(tr('profile.backup.restore.corrupt'));
    }
    if (decoded is! Map) return const [];
    final raw = decoded.cast<String, dynamic>();
    List<dynamic> identities;
    if (raw['encrypted'] == true) {
      if (passphrase.isEmpty) {
        throw BadPassphrase(tr('profile.backup.restore.protected'));
      }
      final inner = await _decrypt(raw, passphrase);
      final innerMap = jsonDecode(inner);
      identities = (innerMap is Map ? innerMap['profiles'] : null) as List? ??
          const [];
    } else {
      identities = (raw['profiles'] as List?) ?? const [];
    }
    return identities
        .whereType<Map>()
        .map((m) => RestorableIdentity.fromJson(m.cast<String, dynamic>()))
        .toList();
  }

  // ── crypto: AES-256-GCM with a PBKDF2-HMAC-SHA256 key ────────────────────
  // PBKDF2 at this iteration count is long pure-Dart work, and backupAll runs
  // on every boot and profile save, so both
  // directions go through compute() (a worker isolate; inline on web).
  Future<Map<String, dynamic>> _encrypt(String plaintext, String passphrase) =>
      compute(_encryptJob, [plaintext, passphrase, _randomBytes(16)]);

  Future<String> _decrypt(Map<String, dynamic> raw, String passphrase) async {
    try {
      return await compute(_decryptJob, [Map<String, dynamic>.of(raw), passphrase]);
    } catch (_) {
      throw BadPassphrase(tr('profile.backup.restore.wrong'));
    }
  }

  List<int> _randomBytes(int n) {
    final r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }
}

Future<SecretKey> _deriveKey(String passphrase, List<int> salt, int iters) {
  final pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iters,
    bits: 256,
  );
  return pbkdf2.deriveKey(
    secretKey: SecretKey(utf8.encode(passphrase)),
    nonce: salt,
  );
}

/// compute() entry point: [plaintext, passphrase, salt].
Future<Map<String, dynamic>> _encryptJob(List<Object> args) async {
  final plaintext = args[0] as String;
  final salt = args[2] as List<int>;
  final key = await _deriveKey(
      args[1] as String, salt, IdentityBackup._kdfIters);
  final algo = AesGcm.with256bits();
  final nonce = algo.newNonce();
  final box = await algo.encrypt(
    utf8.encode(plaintext),
    secretKey: key,
    nonce: nonce,
  );
  return {
    'encrypted': true,
    'kdf': {
      'algo': 'pbkdf2-hmac-sha256',
      'iters': IdentityBackup._kdfIters,
      'salt': base64Encode(salt),
    },
    'iv': base64Encode(nonce),
    'mac': base64Encode(box.mac.bytes),
    'ct': base64Encode(box.cipherText),
  };
}

/// compute() entry point: [raw backup map, passphrase]. Throws on a wrong
/// passphrase or a corrupt file.
Future<String> _decryptJob(List<Object> args) async {
  final raw = args[0] as Map<String, dynamic>;
  final kdf = (raw['kdf'] as Map).cast<String, dynamic>();
  final salt = base64Decode(kdf['salt'] as String);
  final iters = (kdf['iters'] as num?)?.toInt() ?? IdentityBackup._kdfIters;
  final key = await _deriveKey(args[1] as String, salt, iters);
  final algo = AesGcm.with256bits();
  final box = SecretBox(
    base64Decode(raw['ct'] as String),
    nonce: base64Decode(raw['iv'] as String),
    mac: Mac(base64Decode(raw['mac'] as String)),
  );
  final clear = await algo.decrypt(box, secretKey: key);
  return utf8.decode(clear);
}
