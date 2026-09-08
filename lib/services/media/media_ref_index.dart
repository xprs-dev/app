/*
 * media_ref_index — what the conversation said about a file, by hash.
 *
 * A `file:` reference names bytes and nothing else. What lets a receiver
 * decide whether to fetch, what to call the thing, and which original a
 * preview stands for, was said in the packets around it: the `size:` and
 * `name:` on the message (XPRS.md 7.7.1, 7.7.7), and the companion
 * `t:file r:<message id>` describing the full-resolution original of a
 * preview. Those packets go by; the reference is rendered again a week later.
 * So the core keeps the few words that matter, keyed on the hash.
 *
 * Profile database (SQLCipher) like [XprsFileAcl]: what was shared with this
 * profile is this profile's business. Every read is a primary-key lookup, so
 * it is safe on the caller's isolate (docs/architecture.md §2).
 */
import 'package:sqlite3/common.dart';

import '../../profile/profile_db.dart';
import '../../util/media_ref.dart';
import '../xprs/xprs_inline_file.dart';
import '../xprs/xprs_packet.dart';

/// What is known about one referenced file.
class MediaRefInfo {
  const MediaRefInfo({
    required this.sha,
    required this.size,
    required this.name,
    required this.ext,
    required this.from,
    required this.msg,
    required this.role,
  });

  /// 43-char base64url sha.
  final String sha;
  final int? size;
  final String? name;
  final String ext;

  /// The callsign that shared it.
  final String from;

  /// §5 identifier of the message that carried it (`carried`) or that a
  /// `t:file r:` description named (`original`).
  final String msg;

  /// `carried` — the message's own `file:`; `original` — named by a
  /// companion `t:file r:` as the full-resolution file behind a preview.
  final String role;
}

class MediaRefIndex {
  MediaRefIndex._();
  static final MediaRefIndex instance = MediaRefIndex._();

  CommonDatabase? _db;
  bool get ready => _db != null;

  void init(String path) {
    close();
    final db = openProfileDb(path);
    db.execute('''
      CREATE TABLE IF NOT EXISTS media_refs(
        sha   TEXT PRIMARY KEY,
        size  INTEGER,
        name  TEXT,
        ext   TEXT NOT NULL,
        fromc TEXT NOT NULL,
        msg   TEXT NOT NULL,
        role  TEXT NOT NULL,
        ts    INTEGER NOT NULL
      )''');
    db.execute(
        'CREATE INDEX IF NOT EXISTS media_refs_msg ON media_refs(msg, role)');
    _db = db;
  }

  void close() {
    try {
      _db?.dispose();
    } catch (_) {}
    _db = null;
  }

  /// Remember what a packet said about a file. A `t:message` with `file:`
  /// records the file it carries; a `t:file` with `r:` (and no chunk bytes)
  /// records the original it describes for that message. Anything else is
  /// ignored, so this is safe to call for every admitted packet.
  void note(XprsPacket p, {required String msgId}) {
    final db = _db;
    if (db == null) return;
    final fileVal = p['file'];
    if (fileVal == null || fileVal.isEmpty) return;
    final ref = MediaRef.parse('file:$fileVal');
    if (ref == null) return;
    String role;
    String msg;
    if (p.type == 'message') {
      role = 'carried';
      msg = msgId;
    } else if (p.type == 'file' && p.has('r') && !xprsIsInlineChunk(p)) {
      role = 'original';
      msg = (p['r'] ?? '').trim().toLowerCase();
      if (msg.isEmpty) return;
    } else {
      return;
    }
    final size = _bytes(p['size']);
    final name = p['name']?.trim();
    try {
      db.execute(
        'INSERT INTO media_refs(sha,size,name,ext,fromc,msg,role,ts) '
        'VALUES(?,?,?,?,?,?,?,?) '
        'ON CONFLICT(sha) DO UPDATE SET '
        'size=COALESCE(excluded.size,size), name=COALESCE(excluded.name,name), '
        'msg=excluded.msg, role=excluded.role, ts=excluded.ts',
        [
          ref.sha256,
          size,
          (name == null || name.isEmpty) ? null : name,
          ref.ext,
          (p['f'] ?? '').trim().toUpperCase(),
          msg,
          role,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
    } catch (_) {}
  }

  /// What is known about [sha] (43-char base64url or 64-hex). Null when the
  /// hash was never described — an old message with only a `sz:` hint, say.
  MediaRefInfo? describe(String sha) {
    final db = _db;
    if (db == null) return null;
    final key = sha.length == 64 ? MediaRef.hexToB64u(sha) : sha;
    if (key == null) return null;
    try {
      final rows = db.select(
          'SELECT sha,size,name,ext,fromc,msg,role FROM media_refs '
          'WHERE sha=? LIMIT 1',
          [key]);
      if (rows.isEmpty) return null;
      return _row(rows.first);
    } catch (_) {
      return null;
    }
  }

  /// The full-resolution original a preview stands for: the `original` the
  /// same message's `t:file r:` named. Null when the message carried the file
  /// itself.
  MediaRefInfo? originalOf(String previewSha) {
    final db = _db;
    if (db == null) return null;
    final carried = describe(previewSha);
    if (carried == null || carried.role != 'carried' || carried.msg.isEmpty) {
      return null;
    }
    try {
      final rows = db.select(
          'SELECT sha,size,name,ext,fromc,msg,role FROM media_refs '
          "WHERE msg=? AND role='original' AND sha<>? LIMIT 1",
          [carried.msg, carried.sha]);
      if (rows.isEmpty) return null;
      return _row(rows.first);
    } catch (_) {
      return null;
    }
  }

  static MediaRefInfo _row(Row r) => MediaRefInfo(
        sha: r['sha'] as String,
        size: r['size'] as int?,
        name: r['name'] as String?,
        ext: r['ext'] as String,
        from: r['fromc'] as String,
        msg: r['msg'] as String,
        role: r['role'] as String,
      );

  /// `size:` is a quantity with a unit (§15.9); on the wire for files it is
  /// bytes, with `kB`/`MB` tolerated. Null when absent or unreadable.
  static int? _bytes(String? v) {
    if (v == null || v.isEmpty) return null;
    final m = RegExp(r'^(\d+)\s*([kKmMgG]?)[bB]?$').firstMatch(v.trim());
    if (m == null) return null;
    final n = int.tryParse(m.group(1)!);
    if (n == null) return null;
    switch (m.group(2)!.toLowerCase()) {
      case 'k':
        return n * 1000;
      case 'm':
        return n * 1000 * 1000;
      case 'g':
        return n * 1000 * 1000 * 1000;
      default:
        return n;
    }
  }
}
