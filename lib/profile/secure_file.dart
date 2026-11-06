/*
 * Loose profile files that must stay real files (bound by absolute path
 * from RnsService and friends, so they can't live in profile.zx):
 * rns_identity.key, folders.json, and the media archive's blobs.
 *
 * In an encrypted profile each is a one-entry .zx archive (zxPackBytes),
 * encrypted by zx itself: AES-256-CTR + HMAC-SHA-256, the password being
 * the hex of HKDF(PMK, "aurora-file-v1:<profile-relative path>"). There is
 * no encryption code of the app's own here.
 *
 * For plain profiles (no keyslot) reads/writes pass straight through, and
 * a read of a plain file inside an encrypted profile still returns its
 * bytes — the next write encrypts it.
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:zx/zxdb.dart'
    show SevenZipException, zxLooksPacked, zxPackBytes, zxUnpackBytes;

import 'profile_crypto.dart';
import 'profile_db.dart';
import '../platform/fs.dart';

/// A file of an encrypted profile that is unreadable: packed but no key
/// (outside an unlocked profile), or a wrong key / damaged bytes.
class SecureFileException implements Exception {
  final String message;
  const SecureFileException(this.message);
  @override
  String toString() => 'SecureFileException: $message';
}

class SecureProfileFile {
  SecureProfileFile._();

  static UnlockedProfileKeys? _keysFor(String absPath) {
    final loc = locateProfileDb(absPath);
    if (loc == null) return null;
    if (!ProfileKeyring.instance.isEncryptedProfile(loc.profileId)) return null;
    final keys = ProfileKeyring.instance.keysFor(loc.profileId);
    if (keys == null) {
      throw ProfileLockedException(loc.profileId, absPath);
    }
    return keys;
  }

  /// Read [absPath], decrypting when it belongs to an unlocked encrypted
  /// profile. Returns null when the file does not exist. Throws
  /// [ProfileLockedException] / [SecureFileException] on a locked profile
  /// or unreadable content.
  static Uint8List? readBytes(String absPath) {
    final f = fs.file(absPath);
    if (!f.existsSync()) return null;
    // arch-ignore: no-blocking-io-on-ui sync by contract: the WASI fd_* shims read encrypted profile files through here
    final raw = f.readAsBytesSync();
    if (!zxLooksPacked(raw)) return raw; // plain file
    return unwrap(raw, fileKeyFor(absPath));
  }

  /// Write [bytes] to [absPath], encrypting when it belongs to an unlocked
  /// encrypted profile.
  static void writeBytes(String absPath, Uint8List bytes) {
    final parent = fs.file(absPath).parent;
    if (!parent.existsSync()) parent.createSync(recursive: true);
    final key = fileKeyFor(absPath);
    // Media is compressed already; LZ4 gives up on such blocks quickly.
    final out = key == null
        ? bytes
        : zxPackBytes(bytes, password: key, scryptLog2N: 1);
    // arch-ignore: no-blocking-io-on-ui sync by contract: called from the WASI fd_write shim
    fs.file(absPath).writeAsBytesSync(out);
  }

  /// The password that [writeBytes] packs [absPath] with, or null when the
  /// file is written plain (outside an encrypted profile). For a worker
  /// isolate that reads a large file itself ([unwrap]): the keyring lives
  /// on the isolate that unlocked the profile.
  static String? fileKeyFor(String absPath) {
    final keys = _keysFor(absPath);
    if (keys == null) return null;
    return keys.fileKeyHex(locateProfileDb(absPath)!.relPath);
  }

  /// [raw] as [readBytes] returns it, with the password from [fileKeyFor]:
  /// pure, usable on any isolate. A plain file comes back as it is.
  static Uint8List unwrap(Uint8List raw, String? key) {
    if (!zxLooksPacked(raw)) return raw;
    if (key == null) {
      throw const SecureFileException(
          'encrypted file found outside an unlocked encrypted profile');
    }
    try {
      return zxUnpackBytes(raw, password: key);
    } on SevenZipException catch (e) {
      throw SecureFileException(e.message);
    }
  }

  static String? readString(String absPath) {
    final bytes = readBytes(absPath);
    return bytes == null ? null : utf8.decode(bytes);
  }

  static void writeString(String absPath, String content) =>
      writeBytes(absPath, Uint8List.fromList(utf8.encode(content)));
}
