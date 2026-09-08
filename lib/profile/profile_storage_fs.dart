/*
 * ProfileStorage over the filesystem seam (lib/platform/fs.dart).
 *
 * One backend for every target: the real disk on desktop and mobile, the
 * IndexedDB-persisted memory tree on web. It is the plain-file half that
 * EncryptedProfileStorage also builds on.
 */

import 'dart:typed_data';

import 'package:file/file.dart';

import '../platform/fs.dart';
import 'profile_storage.dart';

ProfileStorage makeFilesystemStorage(String basePath) =>
    FilesystemProfileStorage(basePath);

/// Filesystem storage over [fs]. Rooted at an absolute path.
class FilesystemProfileStorage extends ProfileStorage {
  final String _basePath;

  FilesystemProfileStorage(String basePath)
      : _basePath = _stripTrailingSlash(basePath);

  static String _stripTrailingSlash(String p) {
    final sep = pathSeparator;
    while (p.length > 1 && (p.endsWith('/') || p.endsWith(sep))) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  String _resolve(String relativePath) {
    if (relativePath.isEmpty) return _basePath;
    final sep = pathSeparator;
    final native = relativePath.replaceAll('/', sep);
    if (native.startsWith(sep)) return '$_basePath$native';
    return '$_basePath$sep$native';
  }

  @override
  String get basePath => _basePath;

  @override
  bool get isEncrypted => false;

  @override
  String getAbsolutePath(String relativePath) => _resolve(relativePath);

  // ── File ops ──────────────────────────────────────────────────

  @override
  Future<String?> readString(String relativePath) async {
    final f = fs.file(_resolve(relativePath));
    if (!await f.exists()) return null;
    try {
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> readBytes(String relativePath) async {
    final f = fs.file(_resolve(relativePath));
    if (!await f.exists()) return null;
    try {
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> writeString(String relativePath, String content) async {
    final f = fs.file(_resolve(relativePath));
    await f.parent.create(recursive: true);
    await f.writeAsString(content);
  }

  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes) async {
    final f = fs.file(_resolve(relativePath));
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes);
  }

  @override
  Future<void> appendString(String relativePath, String content) async {
    final f = fs.file(_resolve(relativePath));
    await f.parent.create(recursive: true);
    await f.writeAsString(content, mode: FileMode.append);
  }

  @override
  Future<bool> exists(String relativePath) =>
      fs.file(_resolve(relativePath)).exists();

  @override
  Future<void> delete(String relativePath) async {
    final f = fs.file(_resolve(relativePath));
    if (await f.exists()) await f.delete();
  }

  @override
  Future<void> copyFromExternal(
      String externalPath, String relativePath) async {
    final dest = fs.file(_resolve(relativePath));
    await dest.parent.create(recursive: true);
    await fs.file(externalPath).copy(dest.path);
  }

  @override
  Future<void> copyToExternal(
      String relativePath, String externalPath) async {
    final src = fs.file(_resolve(relativePath));
    final dest = fs.file(externalPath);
    await dest.parent.create(recursive: true);
    await src.copy(dest.path);
  }

  // ── Directory ops ─────────────────────────────────────────────

  @override
  Future<List<StorageEntry>> listDirectory(String relativePath,
      {bool recursive = false}) async {
    final d = fs.directory(_resolve(relativePath));
    if (!await d.exists()) return [];
    final out = <StorageEntry>[];
    final sep = pathSeparator;
    final baseWithSep =
        _basePath.endsWith(sep) ? _basePath : '$_basePath$sep';
    await for (final entity in d.list(recursive: recursive)) {
      FileStat stat;
      try {
        stat = await entity.stat();
      } catch (_) {
        continue;
      }
      var entryRel = entity.path;
      if (entryRel.startsWith(baseWithSep)) {
        entryRel = entryRel.substring(baseWithSep.length);
      }
      entryRel = entryRel.replaceAll(sep, '/');
      out.add(StorageEntry(
        name: entity.path.split(sep).last,
        path: entryRel,
        isDirectory: entity is Directory,
        size: entity is File ? stat.size : null,
        modified: stat.modified,
      ));
    }
    return out;
  }

  @override
  Future<void> createDirectory(String relativePath) async {
    await fs.directory(_resolve(relativePath)).create(recursive: true);
  }

  @override
  Future<bool> directoryExists(String relativePath) =>
      fs.directory(_resolve(relativePath)).exists();

  @override
  Future<void> deleteDirectory(String relativePath,
      {bool recursive = false}) async {
    final d = fs.directory(_resolve(relativePath));
    if (await d.exists()) await d.delete(recursive: recursive);
  }

  @override
  Future<void> renameDirectory(
      String fromRelative, String toRelative) async {
    final src = fs.directory(_resolve(fromRelative));
    if (!await src.exists()) return;
    final dest = fs.directory(_resolve(toRelative));
    if (await dest.exists()) return; // never clobber an existing dir
    await dest.parent.create(recursive: true);
    await src.rename(dest.path);
  }

  // ── Sync variants ─────────────────────────────────────────────

  @override
  Uint8List? readBytesSync(String relativePath) {
    final f = fs.file(_resolve(relativePath));
    if (!f.existsSync()) return null;
    try {
      // arch-ignore: no-blocking-io-on-ui the *Sync API exists for the WASI fd_* shims, which cannot await
    return f.readAsBytesSync();
    } catch (_) {
      return null;
    }
  }

  @override
  void writeStringSync(String relativePath, String content) {
    final f = fs.file(_resolve(relativePath));
    f.parent.createSync(recursive: true);
    // arch-ignore: no-blocking-io-on-ui the *Sync API exists for the WASI fd_* shims, which cannot await
    f.writeAsStringSync(content);
  }

  @override
  void writeBytesSync(String relativePath, Uint8List bytes) {
    final f = fs.file(_resolve(relativePath));
    f.parent.createSync(recursive: true);
    // arch-ignore: no-blocking-io-on-ui the *Sync API exists for the WASI fd_* shims, which cannot await
    f.writeAsBytesSync(bytes);
  }

  @override
  bool existsSync(String relativePath) =>
      fs.file(_resolve(relativePath)).existsSync();
}
