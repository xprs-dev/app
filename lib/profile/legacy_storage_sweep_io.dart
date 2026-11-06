/*
 * The storage files of earlier builds, removed once.
 *
 * Every database is a zxdb file now (*.zx), the loose files of an
 * encrypted profile live in profile.zx, and the files that must stay real
 * files are one-entry .zx archives. Earlier builds wrote SQLite (*.sqlite3
 * with -wal, -shm and -journal sidecars), profile.ear (the app's own
 * encrypted archive) and AEF1 files (the app's own AES-GCM wrapper). There
 * is no migration: what those files held is not read (the owner's
 * decision, 2026-11-06). Left alone they are disk space nobody can use,
 * and an AEF1 file would be read as if it were plain, so the first start
 * of this build deletes them, in the background, and leaves a marker so
 * later starts do not walk the tree.
 */
import 'dart:async';
import 'dart:io';

import '../services/log_service.dart';

const String _marker = '.legacy-swept';

/// Delete every file of an earlier storage format under [root] (the
/// profile storage root), once.
Future<void> sweepLegacyStorage(String root) async {
  final dir = Directory(root);
  if (!await dir.exists() || await File('$root/$_marker').exists()) return;
  var files = 0, bytes = 0;
  try {
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      if (!isLegacyStorageFile(e.path) && !_isAef1(e.path)) continue;
      try {
        bytes += await e.length();
        await e.delete();
        files++;
      } catch (_) {}
    }
    await File('$root/$_marker').writeAsString('${DateTime.now().toUtc()}\n');
    if (files > 0) {
      LogService.instance.add('storage: removed $files file(s) of an earlier '
          'storage format (${bytes >> 10} KiB); storage is zx now');
    }
  } catch (e) {
    LogService.instance.add('storage: legacy sweep stopped: $e');
  }
}

/// A file only an earlier build wrote: SQLite, or profile.ear.
bool isLegacyStorageFile(String path) =>
    RegExp(r'\.sqlite3(-wal|-shm|-journal)?$').hasMatch(path) ||
    RegExp(r'(^|/)profile\.ear(-wal|-shm|\.zx-lock)?$').hasMatch(path);

/// True when [path] starts with "AEF1", the app's former AES-GCM wrapper.
bool _isAef1(String path) {
  try {
    final f = File(path).openSync();
    try {
      final head = f.readSync(4);
      return head.length == 4 && String.fromCharCodes(head) == 'AEF1';
    } finally {
      f.closeSync();
    }
  } catch (_) {
    return false;
  }
}
