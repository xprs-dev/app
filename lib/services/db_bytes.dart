/*
 * How big a sqlite database is, asked in a way every platform answers.
 *
 * `PRAGMA page_count` returns an INTEGER on the desktop and a STRING on
 * Android, and three callers here read it as `.values.first as num`. The cast
 * threw on the phone and every one of them swallowed it: the Archiver screen
 * showed "0 B" over 156,000 packets, and — worse, because nobody could see it
 * — the gossip table's byte budget compared 0 against its cap and so never
 * evicted anything on the devices with the least room to spare.
 *
 * One helper, parsing both shapes, so a platform difference cannot quietly
 * turn a budget off again.
 */
import 'package:sqlite3/common.dart';

/// The first column of the first row of [pragma] as an int, or null when the
/// database answered with something that is neither a number nor digits.
int? sqlitePragmaInt(CommonDatabase db, String pragma) {
  try {
    final rows = db.select('PRAGMA $pragma');
    if (rows.isEmpty) return null;
    final v = rows.first.values.first;
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v.trim());
    return null;
  } catch (_) {
    return null;
  }
}

/// Bytes the database occupies, pages × page size, or null when either pragma
/// is unavailable — the caller then decides whether to stat the file or skip
/// the budget rather than silently treating an unknown size as empty.
int? sqliteDbBytes(CommonDatabase db) {
  final pages = sqlitePragmaInt(db, 'page_count');
  final size = sqlitePragmaInt(db, 'page_size');
  if (pages == null || size == null || pages <= 0 || size <= 0) return null;
  return pages * size;
}
