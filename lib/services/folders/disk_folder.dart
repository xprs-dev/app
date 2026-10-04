/*
 * DiskFolderSource — serve an owner's on-disk directory by content hash, WITHOUT
 * copying the files into the sqlite archive. Indexes a directory (sha256 -> path)
 * and serves bytes straight from disk. The folder's master key file and dotfiles
 * are excluded from the index so they are never published or served.
 *
 * Headless: dart:io + crypto only. Used by disk_folder_manager (owner sync) and
 * registered into the file node's serve source via CompositeFileSource.
 */
import 'dart:typed_data';

import 'package:file/file.dart';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show compute;

import '../files/file_transfer.dart' show FileSource, PieceMask, RangedFileSource;
import '../../platform/fs.dart';

/// The hidden key file kept inside an owned folder (excluded from sharing).
const String kFolderKeyFile = '.folder.json';

class DiskFile {
  final String sha; // sha256 hex (64)
  final String name; // path relative to the folder root, '/'-separated
  final int size;
  final String path; // absolute path on disk
  final int mtimeMs; // file modified time (epoch ms)
  const DiskFile(this.sha, this.name, this.size, this.path,
      [this.mtimeMs = 0]);

  String get ext {
    final dot = name.lastIndexOf('.');
    final slash = name.lastIndexOf('/');
    return (dot > slash && dot >= 0) ? name.substring(dot + 1).toLowerCase() : 'bin';
  }
}

/// One cached hash result, keyed by absolute path. Lets a re-scan skip
/// re-hashing a file whose size and mtime are unchanged.
class _HashEntry {
  final int size;
  final int mtimeMs;
  final String sha;
  const _HashEntry(this.size, this.mtimeMs, this.sha);
}

/// Catches the single [crypto.Digest] emitted by a chunked sha256 conversion.
class _DigestCatcher implements Sink<crypto.Digest> {
  crypto.Digest? value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

/// A hash-cache entry as it crosses to a worker isolate: (size, mtimeMs, sha).
typedef _Cached = (int, int, String);

/// What one directory walk produced.
typedef _Walk = ({
  List<DiskFile> files,
  Map<String, String> byHash,
  Map<String, _Cached> cache,
});

class DiskFolderSource implements RangedFileSource {
  final String dirPath;
  final Map<String, String> _byHash = {}; // hex32 -> absolute path
  // Per-file hash cache so a re-scan only re-reads files that actually changed
  // (the sync timer rescans every 60s — without this it re-hashed everything).
  final Map<String, _HashEntry> _hashCache = {}; // abs path -> entry
  List<DiskFile> _files = const [];

  DiskFolderSource(this.dirPath);

  List<DiskFile> get files => _files;
  int get fileCount => _files.length;

  /// (Re)build the index from the directory contents, on the calling isolate.
  /// Returns the file list.
  List<DiskFile> scan() => _apply(_walk(dirPath, _cacheOut()));

  /// Same result as [scan], built on a worker isolate; used at startup and by
  /// the periodic owner sync. The walk (`listSync`, `statSync`) and the sha256
  /// of every changed file used to run here with a yield every 4 MiB, and the
  /// hash cache lives only in memory, so each launch re-hashed every shared
  /// file on the UI isolate: 12.8 s of main-isolate CPU in the first 30 s on
  /// the desktop, and typing lagged until it finished (architecture.md 2).
  Future<List<DiskFile>> scanAsync() async =>
      _apply(await compute(_walkOffThread, (dirPath, _cacheOut())));

  static _Walk _walkOffThread((String, Map<String, _Cached>) m) =>
      _walk(m.$1, m.$2);

  Map<String, _Cached> _cacheOut() => {
        for (final e in _hashCache.entries)
          e.key: (e.value.size, e.value.mtimeMs, e.value.sha),
      };

  List<DiskFile> _apply(_Walk walked) {
    _hashCache
      ..clear()
      ..addAll({
        for (final e in walked.cache.entries)
          e.key: _HashEntry(e.value.$1, e.value.$2, e.value.$3),
      });
    // Swap in the freshly-built index atomically.
    _byHash
      ..clear()
      ..addAll(walked.byHash);
    _files = walked.files;
    return _files;
  }

  /// Index [dirPath], reusing [cache] for files whose size and mtime are
  /// unchanged. Self-contained so it can run on any isolate.
  static _Walk _walk(String dirPath, Map<String, _Cached> cache) {
    final out = <DiskFile>[];
    final byHash = <String, String>{};
    final kept = <String, _Cached>{};
    final root = fs.directory(dirPath);
    if (!root.existsSync()) {
      return (files: const <DiskFile>[], byHash: byHash, cache: kept);
    }
    final base = root.absolute.path;
    for (final e in root.listSync(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final abs = e.absolute.path;
      var rel = abs.startsWith(base) ? abs.substring(base.length) : abs;
      rel = rel.replaceAll('\\', '/');
      if (rel.startsWith('/')) rel = rel.substring(1);
      // Skip the key file and any dot-prefixed file or path segment.
      if (rel.isEmpty) continue;
      if (rel == kFolderKeyFile) continue;
      if (rel.split('/').any((s) => s.startsWith('.'))) continue;
      try {
        final stat = e.statSync();
        final size = stat.size;
        final mtime = stat.modified.millisecondsSinceEpoch;
        final cached = cache[abs];
        final String sha;
        if (cached != null && cached.$1 == size && cached.$2 == mtime) {
          sha = cached.$3; // unchanged: reuse, no re-read
        } else {
          sha = _hashFile(e); // streaming hash, bounded memory
        }
        // Only files still present are kept, so vanished ones drop out.
        kept[abs] = (size, mtime, sha);
        byHash[sha] = abs;
        out.add(DiskFile(sha, rel, size, abs, mtime));
      } catch (_) {
        // unreadable file: skip it
      }
    }
    return (files: out, byHash: byHash, cache: kept);
  }

  /// sha256 of a file read in fixed-size chunks, so memory stays bounded
  /// regardless of file size (the old readAsBytesSync loaded the whole file;
  /// over a big shared tree that was the out-of-memory).
  static String _hashFile(File f) {
    final catcher = _DigestCatcher();
    final input = crypto.sha256.startChunkedConversion(catcher);
    final raf = f.openSync();
    try {
      const chunkSize = 1 << 16; // 64 KiB
      while (true) {
        final chunk = raf.readSync(chunkSize);
        if (chunk.isEmpty) break;
        input.add(chunk);
      }
    } finally {
      raf.closeSync();
    }
    input.close();
    return _hex(catcher.value!.bytes);
  }

  @override
  Uint8List? read(Uint8List fileHash) {
    final path = _byHash[_hex(fileHash)];
    if (path == null) return null;
    try {
      return fs.file(path).readAsBytesSync();
    } catch (_) {
      return null;
    }
  }

  bool has(Uint8List fileHash) => _byHash.containsKey(_hex(fileHash));

  /// The file's real path on disk, when this folder is the one serving it.
  /// Opening a file with the OS needs a PATH, not bytes — [read] would pull the
  /// whole thing into memory to hand a viewer something it can open itself.
  String? pathOfHex(String shaHex) => _byHash[shaHex.toLowerCase()];

  // ── Serving PIECES (docs/torrents.md §8 step 2) ───────────────────────────
  //
  // A disk folder is the best possible piece server: the bytes are already a
  // file, so serving a range is a seek and a read — a 4 GB film is served one
  // piece at a time without ever holding 4 GB in memory (which [read] would).

  @override
  Uint8List? readRange(Uint8List fileHash, int offset, int length) {
    final path = _byHash[_hex(fileHash)];
    if (path == null) return null;
    RandomAccessFile? raf;
    try {
      final f = fs.file(path);
      final size = f.lengthSync();
      if (offset < 0 || offset >= size) return null;
      final end = (offset + length > size) ? size : offset + length;
      raf = f.openSync();
      raf.setPositionSync(offset);
      return raf.readSync(end - offset);
    } catch (_) {
      return null;
    } finally {
      raf?.closeSync();
    }
  }

  @override
  PieceMask? pieceMask(Uint8List fileHash, int pieceSize) {
    final path = _byHash[_hex(fileHash)];
    if (path == null) return null;
    try {
      // We hold the whole file (it is on disk and its hash is in our index), so
      // we hold every piece of it.
      return PieceMask.full(fs.file(path).lengthSync(), pieceSize);
    } catch (_) {
      return null;
    }
  }

  static String _hex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
