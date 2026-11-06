/*
 * Encrypted profile storage backend (docs/plan-encrypted-storage.md).
 *
 * Every byte of an encrypted profile is encrypted by zx itself; the app
 * has no cipher code of its own. The profile's file tree is routed to:
 *
 *   - profile.zx: a zxdb database encrypted with the store password
 *     (HKDF of the profile master key) holding every loose user file —
 *     data/<wapp>/kv.json, hal_file_* files, avatar.png, chat JSON, … —
 *     as rows of `files` (path, data, mtime), and the empty directories
 *     made explicitly in `dirs`.
 *   - filesystem passthrough: things that MUST be real files —
 *       * wapp packages (`wapps/…`, public software, scope decision)
 *       * every database (`*.zx`): each encrypted by its own password via
 *         openProfileDb; live handles can't run inside another database
 *       * files bound by absolute path from RnsService and the media
 *         archive's blobs (`data/media/`): the secret ones are one-entry
 *         .zx archives, encrypted by zx (SecureProfileFile)
 *       * the keyslot and seed markers
 *
 * profile.zx opens on first use (synchronously: its key costs no
 * stretching) and closes when the profile locks.
 */

import 'dart:convert';
import 'dart:typed_data';

import 'package:reticulum/reticulum.dart' show XDb, xdbOpenFile;

import '../platform/fs.dart';
import 'profile_db.dart';
import 'profile_storage.dart';
import 'profile_storage_fs.dart';

/// Name of the per-profile encrypted file store.
const String profileStoreName = 'profile.zx';

class EncryptedProfileStorage extends ProfileStorage {
  final String profileId;
  final String _basePath; // absolute devices/<id>, no trailing slash
  final FilesystemProfileStorage _fs;

  EncryptedProfileStorage(this.profileId, String basePath)
      : _basePath = _stripTrailingSlash(basePath),
        _fs = FilesystemProfileStorage(basePath) {
    _registerLockHook();
  }

  static String _stripTrailingSlash(String p) {
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  // ── the shared store of each profile ───────────────────────────────────

  static final Map<String, XDb> _stores = {};
  static bool _hookRegistered = false;

  static void _registerLockHook() {
    if (_hookRegistered) return;
    _hookRegistered = true;
    ProfileKeyring.instance.onLock.add(closeStore);
  }

  /// Close the store of [profileId]; the next access opens it again (and
  /// throws [ProfileLockedException] while the profile is locked). Called
  /// when the keyring locks a profile.
  static Future<void> closeStore(String profileId) async {
    _stores.remove(profileId)?.dispose();
  }

  static Future<void> closeAllStores() async {
    for (final id in _stores.keys.toList()) {
      await closeStore(id);
    }
  }

  XDb get _db {
    final open = _stores[profileId];
    if (open != null) return open;
    final keys = ProfileKeyring.instance.keysFor(profileId);
    if (keys == null) throw ProfileLockedException(profileId, _basePath);
    final db = xdbOpenFile('$_basePath/$profileStoreName',
        password: keys.storePassword, durable: true);
    db.execute('CREATE TABLE IF NOT EXISTS files ('
        'path TEXT PRIMARY KEY, data BLOB NOT NULL, mtime INTEGER NOT NULL)');
    db.execute('CREATE TABLE IF NOT EXISTS dirs (path TEXT PRIMARY KEY)');
    return _stores[profileId] = db;
  }

  // ── absolute-path bridge (WASM HAL etc.) ───────────────────────────────

  /// For code that only has an absolute path: returns the encrypted storage
  /// + profile-relative path when [absPath] falls inside an encrypted
  /// profile AND is routed to profile.zx. Null → caller should use dart:io.
  static ({EncryptedProfileStorage storage, String rel})? routeAbsolutePath(
      String absPath) {
    final loc = locateProfileDb(absPath);
    if (loc == null) return null;
    if (!ProfileKeyring.instance.isEncryptedProfile(loc.profileId)) return null;
    if (isPassthroughPath(loc.relPath)) return null;
    final root = '${profileStorageRoot()}/devices/${loc.profileId}';
    return (
      storage: EncryptedProfileStorage(loc.profileId, root),
      rel: loc.relPath,
    );
  }

  // ── routing ────────────────────────────────────────────────────────────

  /// Files that RnsService & friends bind by ABSOLUTE path and read/write
  /// with dart:io — they must stay real files. The secrets among them
  /// (rns_identity.key, folders.json) are one-entry encrypted .zx archives
  /// (SecureProfileFile). If you add a new absolute-path file to
  /// rns_autostart, add it here too, or it will land in profile.zx and
  /// dart:io access will break for encrypted profiles.
  static const Set<String> _passthroughFiles = {
    'data/rns_identity.key',
    'data/folders.json',
    'data/call_peers.json',
    'data/disk_folders.json',
    'data/folder_subscriptions.json',
    'data/host_follows.json',
    'data/hero_inbox.json',
    'data/hero_media.json',
  };

  static const List<String> _passthroughPrefixes = [
    'wapps/', // wapp packages (public software) + their databases
    'data/partials/', // resumable-download chunks, dart:io dir scans
    'data/mesh/', // mesh bulk custody chunks (dart:io, MeshService)
    'data/share/', // MediaFileSource share dir (dart:io, reticulum)
    'data/media/', // MediaArchive blob files (packed .zx, SecureProfileFile)
  ];

  static bool isPassthroughPath(String relativePath) {
    final p = _normalizeRel(relativePath);
    if (p.isEmpty) return false;
    if (p == keyslotFileName) return true;
    if (p.startsWith('.seeded')) return true;
    // zxdb files and their writer locks (`x.zx`, `x.zx-lock`), profile.zx
    // itself among them.
    if (RegExp(r'\.zx($|-)').hasMatch(p)) return true;
    if (_passthroughFiles.contains(p)) return true;
    for (final prefix in _passthroughPrefixes) {
      if (p.startsWith(prefix) || p == prefix.substring(0, prefix.length - 1)) {
        return true;
      }
    }
    return false;
  }

  static String _normalizeRel(String relativePath) {
    var p = relativePath.replaceAll('\\', '/');
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    while (p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p.replaceAll(RegExp(r'/+'), '/');
  }

  // ── ProfileStorage interface ───────────────────────────────────────────

  @override
  String get basePath => _basePath;

  @override
  bool get isEncrypted => true;

  @override
  String getAbsolutePath(String relativePath) =>
      _fs.getAbsolutePath(relativePath);

  // the store's primitives, synchronous (zxdb is)

  Uint8List? _read(String p) {
    final rows =
        _db.select('SELECT data FROM files WHERE path = ? LIMIT 1', [p]);
    if (rows.isEmpty) return null;
    final v = rows.first['data'];
    return v is Uint8List ? v : Uint8List.fromList((v as List).cast<int>());
  }

  void _write(String p, Uint8List bytes) {
    _db.execute(
        'INSERT INTO files (path, data, mtime) VALUES (?, ?, ?) '
        'ON CONFLICT(path) DO UPDATE SET data = excluded.data, '
        'mtime = excluded.mtime',
        [p, bytes, DateTime.now().millisecondsSinceEpoch]);
  }

  bool _has(String p) => _exists('SELECT 1 FROM files WHERE path = ?', [p]);

  /// Whether the query [sql] has a row (asked as EXISTS: no rows built).
  bool _exists(String sql, List<Object?> params) =>
      _db.select('SELECT EXISTS ($sql) AS e LIMIT 1', params).first['e'] == 1;

  static const _underDir = 'substr(path, 1, ?) = ?';

  /// Rows of `files` below directory [p] ('' is the root).
  List<Map<String, dynamic>> _below(String p) {
    const cols = 'path, length(data) AS size, mtime';
    // The listing is this store's contract: every file under [p].
    // arch-ignore: no-unbounded-select a directory listing returns every entry by contract; the store owner pages nothing
    if (p.isEmpty) return _db.select('SELECT $cols FROM files');
    return _db.select(
        'SELECT $cols FROM files WHERE substr(path, 1, ?) = ?',
        [p.length + 1, '$p/']);
  }

  List<String> _dirsBelow(String p) => [
        for (final r in p.isEmpty
            // arch-ignore: no-unbounded-select a directory listing returns every entry by contract
            ? _db.select('SELECT path FROM dirs')
            // arch-ignore: no-unbounded-select a directory listing returns every entry by contract
            : _db.select('SELECT path FROM dirs WHERE substr(path, 1, ?) = ?',
                [p.length + 1, '$p/']))
          r['path'] as String
      ];

  @override
  Future<String?> readString(String relativePath) async {
    final bytes = await readBytes(relativePath);
    if (bytes == null) return null;
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Uint8List?> readBytes(String relativePath) async =>
      readBytesSync(relativePath);

  @override
  Future<void> writeString(String relativePath, String content) =>
      writeBytes(relativePath, Uint8List.fromList(utf8.encode(content)));

  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.writeBytes(p, bytes);
    _write(p, bytes);
  }

  @override
  Future<void> appendString(String relativePath, String content) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.appendString(p, content);
    final existing = _read(p);
    final add = Uint8List.fromList(utf8.encode(content));
    if (existing == null) return _write(p, add);
    _write(
        p,
        Uint8List(existing.length + add.length)
          ..setRange(0, existing.length, existing)
          ..setRange(existing.length, existing.length + add.length, add));
  }

  @override
  Future<bool> exists(String relativePath) async => existsSync(relativePath);

  @override
  Future<void> delete(String relativePath) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.delete(p);
    // deleting a missing file is a no-op, as on the filesystem
    _db.execute('DELETE FROM files WHERE path = ?', [p]);
  }

  @override
  Future<void> copyFromExternal(String externalPath, String relativePath) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.copyFromExternal(externalPath, p);
    // A row holds the whole file.
    // arch-ignore: no-whole-file-read a profile.zx row holds the whole file; loose user files are small
    _write(p, await fs.file(externalPath).readAsBytes());
  }

  @override
  Future<void> copyToExternal(String relativePath, String externalPath) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.copyToExternal(p, externalPath);
    final bytes = _read(p);
    if (bytes == null) {
      throw StateError('no file $p in the profile store');
    }
    final out = fs.file(externalPath);
    await out.parent.create(recursive: true);
    await out.writeAsBytes(bytes, flush: true);
  }

  // ── directory ops ──────────────────────────────────────────────────────

  @override
  Future<List<StorageEntry>> listDirectory(String relativePath,
      {bool recursive = false}) async {
    final p = _normalizeRel(relativePath);

    // Merge: filesystem side (wapps/, .zx files, markers) + profile.zx.
    final out = <String, StorageEntry>{};

    if (await _fs.directoryExists(p)) {
      for (final e in await _fs.listDirectory(p, recursive: recursive)) {
        // Hide the store and the keyslot from listings of the root.
        if (e.path == profileStoreName ||
            e.path.startsWith('$profileStoreName-') ||
            e.path == keyslotFileName) {
          continue;
        }
        out[e.path] = e;
      }
    }

    final prefix = p.isEmpty ? '' : '$p/';
    void addDir(String dirPath) => out.putIfAbsent(
        dirPath,
        () => StorageEntry(
            name: dirPath.substring(dirPath.lastIndexOf('/') + 1),
            path: dirPath,
            isDirectory: true));
    // A path below [p]: itself when it is a direct child (or recursive),
    // else its first directory below [p].
    void addPath(String path, StorageEntry Function() entry) {
      final tail = path.substring(prefix.length);
      if (tail.isEmpty) return;
      if (!recursive && tail.contains('/')) {
        addDir(prefix + tail.substring(0, tail.indexOf('/')));
        return;
      }
      if (recursive) {
        // the directories between [p] and the path
        var i = tail.indexOf('/');
        while (i >= 0) {
          addDir(prefix + tail.substring(0, i));
          i = tail.indexOf('/', i + 1);
        }
      }
      out[path] = entry();
    }

    for (final d in _dirsBelow(p)) {
      addPath(d, () => StorageEntry(
          name: d.substring(d.lastIndexOf('/') + 1),
          path: d,
          isDirectory: true));
    }
    for (final r in _below(p)) {
      final path = r['path'] as String;
      addPath(
          path,
          () => StorageEntry(
                name: path.substring(path.lastIndexOf('/') + 1),
                path: path,
                isDirectory: false,
                size: (r['size'] as num?)?.toInt(),
                modified: DateTime.fromMillisecondsSinceEpoch(
                    (r['mtime'] as num).toInt()),
              ));
    }
    return out.values.toList();
  }

  @override
  Future<void> createDirectory(String relativePath) async {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.createDirectory(p);
    // Real directory too: .zx files / passthrough children of this
    // directory need it to exist on disk.
    await _fs.createDirectory(p);
    if (p.isEmpty) return;
    _db.execute('INSERT OR IGNORE INTO dirs (path) VALUES (?)', [p]);
  }

  @override
  Future<bool> directoryExists(String relativePath) async {
    final p = _normalizeRel(relativePath);
    if (await _fs.directoryExists(p)) return true;
    if (isPassthroughPath(p)) return false;
    final under = [p.length + 1, '$p/'];
    return _exists('SELECT 1 FROM dirs WHERE path = ?', [p]) ||
        _exists('SELECT 1 FROM files WHERE $_underDir', under) ||
        _exists('SELECT 1 FROM dirs WHERE $_underDir', under);
  }

  @override
  Future<void> deleteDirectory(String relativePath, {bool recursive = false}) async {
    final p = _normalizeRel(relativePath);
    if (await _fs.directoryExists(p)) {
      await _fs.deleteDirectory(p, recursive: recursive);
    }
    if (isPassthroughPath(p)) return;
    _db.transaction(() {
      if (recursive) {
        _db.execute('DELETE FROM files WHERE substr(path, 1, ?) = ?',
            [p.length + 1, '$p/']);
        _db.execute('DELETE FROM dirs WHERE substr(path, 1, ?) = ?',
            [p.length + 1, '$p/']);
      }
      _db.execute('DELETE FROM dirs WHERE path = ?', [p]);
    });
  }

  @override
  Future<void> renameDirectory(String fromRelative, String toRelative) async {
    final from = _normalizeRel(fromRelative);
    final to = _normalizeRel(toRelative);
    if (from.isEmpty || to.isEmpty || from == to) return;
    if (await directoryExists(to)) return;

    if (await _fs.directoryExists(from)) {
      await _fs.renameDirectory(from, to);
    }
    if (isPassthroughPath(from)) return;

    final n = from.length + 1;
    _db.transaction(() {
      for (final table in ['files', 'dirs']) {
        _db.execute(
            'UPDATE $table SET path = ? || substr(path, ?) '
            'WHERE substr(path, 1, ?) = ?',
            ['$to/', n + 1, n, '$from/']);
      }
      _db.execute('UPDATE dirs SET path = ? WHERE path = ?', [to, from]);
    });
  }

  // ── sync variants (WASM HAL) ───────────────────────────────────────────

  @override
  Uint8List? readBytesSync(String relativePath) {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.readBytesSync(p);
    return _read(p);
  }

  @override
  void writeStringSync(String relativePath, String content) =>
      writeBytesSync(relativePath, Uint8List.fromList(utf8.encode(content)));

  @override
  void writeBytesSync(String relativePath, Uint8List bytes) {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) {
      _fs.writeBytesSync(p, bytes);
      return;
    }
    _write(p, bytes);
  }

  @override
  bool existsSync(String relativePath) {
    final p = _normalizeRel(relativePath);
    if (isPassthroughPath(p)) return _fs.existsSync(p);
    return _has(p);
  }
}
