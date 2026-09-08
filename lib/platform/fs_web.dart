/*
 * Web half of the filesystem seam: an in-memory POSIX tree that persists to
 * IndexedDB.
 *
 * Why memory + persistence rather than a filesystem over IndexedDB directly:
 * IndexedDB is asynchronous and the WASM HAL callbacks (hal_file_*, the WASI
 * fd_* shims) are synchronous, so the tree the wapps see has to be in memory.
 * What IndexedDB adds is survival across reloads.
 *
 * How persistence works: no write path is wrapped. A timer walks the tree,
 * stats every entry (a MemoryFileSystem stat is a map lookup), and compares
 * (mtime, size, kind) against what was last committed; changed entries are
 * put, vanished ones deleted, in one readwrite transaction. That catches
 * writeAsBytes, openWrite, RandomAccessFile, rename and delete alike, which a
 * wrapper would have to intercept one by one. [flushFs] runs the same pass
 * on demand and awaits the commit; `pagehide`/`visibilitychange` call it.
 *
 * Bytes live in the heap twice over at most (tree + the transaction's copy),
 * so this is for profile data, wapp packages and settings -- not a media
 * archive. Quota is the browser's (docs/web.md).
 *
 * The old localStorage backend (profile_storage_web.dart, removed) kept every
 * store as a base64 JSON blob under `xprs.storage:<basePath>`; those are
 * carried into the tree once at first boot and the keys dropped, so a web
 * profile created before this file keeps its data.
 */
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:web/web.dart' as web;

import '../services/log_service.dart';

final MemoryFileSystem _mem = MemoryFileSystem(style: FileSystemStyle.posix);

FileSystem get fs => _mem;

String get pathSeparator => '/';

const String _dbName = 'xprs-fs';
const String _storeName = 'files';
const Duration _scanEvery = Duration(milliseconds: 500);

web.IDBDatabase? _db;
Timer? _scan;
Future<void>? _inFlight;

/// What IndexedDB holds for one path, as last committed.
class _Committed {
  final bool dir;
  final int mtimeMs;
  final int size;
  const _Committed(this.dir, this.mtimeMs, this.size);
}

final Map<String, _Committed> _committed = {};

/// Open IndexedDB, replay it into the tree, migrate any localStorage-era
/// stores, start the write-behind timer. Idempotent.
Future<void> initFs() async {
  if (_db != null) return;
  final db = await _open();
  _db = db;
  await _hydrate(db);
  _migrateLocalStorage();
  _scan ??= Timer.periodic(_scanEvery, (_) => _kick());
  void onLeave(web.Event _) => flushFs();
  web.window.addEventListener('pagehide', onLeave.toJS);
  web.document.addEventListener(
      'visibilitychange',
      ((web.Event _) {
        if (web.document.visibilityState == 'hidden') flushFs();
      }).toJS);
}

/// Commit every pending change and wait for IndexedDB to confirm it.
Future<void> flushFs() {
  final f = _inFlight;
  if (f != null) return f.then((_) => _commitDiff());
  return _commitDiff();
}

void _kick() {
  if (_inFlight != null) return;
  _commitDiff();
}

// ── IndexedDB plumbing ──────────────────────────────────────────────────────

Future<T> _await<T>(web.IDBRequest req) {
  final c = Completer<T>();
  req.onsuccess = ((web.Event _) => c.complete(req.result as T)).toJS;
  req.onerror = ((web.Event _) => c.completeError(
      StateError('IndexedDB request failed: ${req.error?.message}'))).toJS;
  return c.future;
}

Future<web.IDBDatabase> _open() {
  final c = Completer<web.IDBDatabase>();
  final req = web.window.indexedDB.open(_dbName, 1);
  req.onupgradeneeded = ((web.Event _) {
    final db = req.result as web.IDBDatabase;
    if (!db.objectStoreNames.contains(_storeName)) {
      db.createObjectStore(
          _storeName, web.IDBObjectStoreParameters(keyPath: 'path'.toJS));
    }
  }).toJS;
  req.onsuccess =
      ((web.Event _) => c.complete(req.result as web.IDBDatabase)).toJS;
  req.onerror = ((web.Event _) => c.completeError(
      StateError('IndexedDB open failed: ${req.error?.message}'))).toJS;
  return c.future;
}

Future<void> _hydrate(web.IDBDatabase db) async {
  final tx = db.transaction(_storeName.toJS, 'readonly');
  final all = await _await<JSArray<JSObject>>(tx.objectStore(_storeName).getAll());
  for (final rec in all.toDart) {
    final m = rec.dartify();
    if (m is! Map) continue;
    final path = m['path'];
    if (path is! String) continue;
    final dir = m['dir'] == true;
    try {
      if (dir) {
        _mem.directory(path).createSync(recursive: true);
      } else {
        final raw = m['bytes'];
        final bytes = raw is Uint8List
            ? raw
            : raw is List ? Uint8List.fromList(raw.cast<int>()) : Uint8List(0);
        final f = _mem.file(path);
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(bytes);
      }
      final st = _mem.statSync(path);
      _committed[path] =
          _Committed(dir, st.modified.millisecondsSinceEpoch, st.size);
    } catch (_) {
      // A record the tree refuses (a file where a directory now is) is
      // dropped on the next commit rather than crashing the boot.
    }
  }
}

/// One pass: stat the tree, put what changed, delete what vanished.
Future<void> _commitDiff() {
  final db = _db;
  if (db == null) return Future.value();
  final current = <String, _Committed>{};
  final changedFiles = <String>[];
  final changedDirs = <String>[];
  void visit(Directory d) {
    for (final e in d.listSync(followLinks: false)) {
      final st = e.statSync();
      final isDir = st.type == FileSystemEntityType.directory;
      final now = _Committed(isDir, st.modified.millisecondsSinceEpoch, st.size);
      current[e.path] = now;
      final was = _committed[e.path];
      if (was == null ||
          was.dir != now.dir ||
          (!isDir && (was.mtimeMs != now.mtimeMs || was.size != now.size))) {
        (isDir ? changedDirs : changedFiles).add(e.path);
      }
      if (isDir) visit(e as Directory);
    }
  }
  try {
    visit(_mem.directory('/'));
  } catch (_) {
    return Future.value();
  }
  final gone = _committed.keys.where((p) => !current.containsKey(p)).toList();
  if (changedFiles.isEmpty && changedDirs.isEmpty && gone.isEmpty) {
    return Future.value();
  }
  final c = Completer<void>();
  _inFlight = c.future;
  try {
    final tx = db.transaction(_storeName.toJS, 'readwrite');
    final store = tx.objectStore(_storeName);
    for (final p in changedDirs) {
      store.put({'path': p, 'dir': true}.jsify());
    }
    for (final p in changedFiles) {
      Uint8List bytes;
      try {
        bytes = _mem.file(p).readAsBytesSync();
      } catch (_) {
        continue; // vanished between the stat and the read; next pass
      }
      final req = store.put({'path': p, 'dir': false, 'bytes': bytes}.jsify());
      req.onerror = ((web.Event _) {
        LogService.instance.add(
            'fs(web): put $p (${bytes.length} B) failed: ${req.error?.name} '
            '${req.error?.message}');
      }).toJS;
    }
    for (final p in gone) {
      store.delete(p.toJS);
    }
    void finish() {
      if (c.isCompleted) return;
      _inFlight = null;
      c.complete();
    }
    tx.oncomplete = ((web.Event _) {
      for (final p in gone) {
        _committed.remove(p);
      }
      for (final p in [...changedDirs, ...changedFiles]) {
        final v = current[p];
        if (v != null) _committed[p] = v;
      }
      finish();
    }).toJS;
    // A failed request bubbles here once per request, then the transaction
    // aborts. The tree keeps working for the session; the next pass retries
    // everything that is still different. Say why, once per transaction.
    tx.onerror = ((web.Event _) {
      if (!c.isCompleted) {
        LogService.instance.add(
            'fs(web): commit of ${changedFiles.length} files, '
            '${changedDirs.length} dirs, ${gone.length} deletes failed: '
            '${tx.error?.name} ${tx.error?.message}');
      }
      finish();
    }).toJS;
    tx.onabort = ((web.Event _) => finish()).toJS;
  } catch (e) {
    LogService.instance.add('fs(web): commit threw: $e');
    _inFlight = null;
    if (!c.isCompleted) c.complete();
  }
  return c.future;
}

// ── localStorage carry-over ─────────────────────────────────────────────────

const _legacyPrefixes = ['xprs.storage:', 'geogram.storage:'];

void _migrateLocalStorage() {
  final ls = web.window.localStorage;
  final keys = <String>[];
  for (var i = 0; i < ls.length; i++) {
    final k = ls.key(i);
    if (k != null && _legacyPrefixes.any(k.startsWith)) keys.add(k);
  }
  for (final k in keys) {
    try {
      final base = k.substring(k.indexOf(':') + 1);
      final decoded = jsonDecode(ls.getItem(k) ?? '');
      if (decoded is Map) {
        for (final e in decoded.entries) {
          final v = e.value;
          if (v is! String) continue;
          final f = _mem.file('$base/${e.key}');
          if (f.existsSync()) continue; // the tree already has a newer copy
          f.parent.createSync(recursive: true);
          f.writeAsBytesSync(base64Decode(v));
        }
      }
    } catch (_) {
      // Undecodable blob: drop it, the tree is the store now.
    }
    ls.removeItem(k);
  }
}
