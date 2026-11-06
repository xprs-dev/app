/*
 * The SQLite files of earlier builds, removed once.
 *
 * Every database is a zxdb file now (*.zx). The app used SQLite before
 * (*.sqlite3 with -wal, -shm and -journal sidecars, and a SQLite-format
 * profile.ear), and there is no migration: what those files held is not
 * read (the owner's decision, 2026-11-06). Left alone they are disk space
 * nobody can use, so the first start of a zxdb build deletes them, in the
 * background, and leaves a marker so later starts do not walk the tree.
 */
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../services/log_service.dart';

const String _marker = '.sqlite-swept';

/// Delete every SQLite file under [root] (the profile storage root), once.
Future<void> sweepLegacySqlite(String root) async {
  final dir = Directory(root);
  if (!await dir.exists() || await File('$root/$_marker').exists()) return;
  var files = 0, bytes = 0;
  try {
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      if (!isLegacySqliteFile(e.path)) continue;
      try {
        bytes += await e.length();
        await e.delete();
        files++;
      } catch (_) {}
    }
    await File('$root/$_marker').writeAsString('${DateTime.now().toUtc()}\n');
    if (files > 0) {
      LogService.instance.add('storage: removed $files SQLite file(s) of an '
          'earlier build (${bytes >> 10} KiB); databases are zxdb now');
    }
  } catch (e) {
    LogService.instance.add('storage: SQLite sweep stopped: $e');
  }
}

/// A file only an earlier, SQLite build wrote.
bool isLegacySqliteFile(String path) =>
    RegExp(r'\.sqlite3(-wal|-shm|-journal)?$').hasMatch(path) ||
    RegExp(r'profile\.ear-(wal|shm)$').hasMatch(path);

/// True when [path] is a SQLite database (an earlier build's profile.ear):
/// its first 16 bytes are "SQLite format 3\0".
bool isSqliteFile(String path) {
  try {
    final f = File(path).openSync();
    try {
      final head = f.readSync(16);
      return head.length == 16 &&
          String.fromCharCodes(Uint8List.sublistView(head, 0, 15)) ==
              'SQLite format 3';
    } finally {
      f.closeSync();
    }
  } catch (_) {
    return false;
  }
}
