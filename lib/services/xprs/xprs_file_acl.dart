/*
 * xprs_file_acl — who may fetch the BYTES behind a `file:` hash (XPRS.md §11.2).
 *
 * The hash is public: `q:have`/`have:` and the seeder index advertise it freely,
 * and anyone may learn who holds it. Serving the bytes is a separate decision.
 * A `cmd:file` ask carries the requester's callsign and a signature; an archiver
 * serves only if that callsign is AUTHORISED for the file. Authorisation is the
 * audience of the message that shared the file:
 *
 *   public  an undirected post — anyone may fetch it.
 *   group   a closed group — a current member may fetch it (the same membership
 *           the core already enforces on posting, XprsGroups.mayPost).
 *   pair    a 1:1 message — either of the two participants may fetch it.
 *
 * This binds `hash → audience` when a message referencing the hash is admitted
 * or composed, so the file inherits the reach of the words that carried it. A
 * hash with no binding is treated as public (a bare digest an operator pinned,
 * an update-mirror artifact): the default is open, private is a deliberate bind.
 *
 * It lives in the profile database (SQLCipher), like [XprsPassphrases] and
 * [XprsGroupKeys]: the audience of a private picture is the profile's business.
 * Lookups are single-row primary-key reads, never a scan — safe on the caller's
 * isolate (docs/architecture.md §2).
 */
import 'package:sqlite3/common.dart';

import '../../profile/profile_db.dart';
import '../../util/media_ref.dart';
import 'xprs_groups.dart';
import 'xprs_packet.dart';

/// The reach of a shared file — the audience of the message that carried it.
enum XprsFileScope { public, group, pair }

class XprsFileAcl {
  XprsFileAcl._();
  static final XprsFileAcl instance = XprsFileAcl._();

  CommonDatabase? _db;
  bool get ready => _db != null;

  void init(String path) {
    close();
    final db = openProfileDb(path);
    db.execute('''
      CREATE TABLE IF NOT EXISTS xprs_file_acl(
        sha     TEXT PRIMARY KEY,
        scope   TEXT NOT NULL,
        grp     TEXT,
        members TEXT
      )''');
    _db = db;
  }

  void close() {
    try {
      _db?.dispose();
    } catch (_) {}
    _db = null;
  }

  static String _base(String c) => c.trim().split('-').first.toUpperCase();

  /// Bind [shaHex] to an audience. A later bind for the same hash replaces the
  /// earlier one (a group's membership shifts; the newest word wins). A public
  /// bind is recorded too, so re-sharing a picture publicly re-opens it.
  void bind(
    String shaHex, {
    required XprsFileScope scope,
    String? group,
    List<String> members = const [],
  }) {
    final db = _db;
    final sha = shaHex.trim().toLowerCase();
    if (db == null || sha.isEmpty) return;
    try {
      db.execute(
        'INSERT INTO xprs_file_acl(sha, scope, grp, members) VALUES(?,?,?,?) '
        'ON CONFLICT(sha) DO UPDATE SET scope=excluded.scope, '
        'grp=excluded.grp, members=excluded.members',
        [
          sha,
          scope.name,
          group == null ? null : _base(group),
          members.map(_base).where((c) => c.isNotEmpty).join(','),
        ],
      );
    } catch (_) {}
  }

  /// Bind every `file:` reference in [msg]'s body to the message's own audience.
  /// Called both when THIS station composes a message ([own]) and when it admits
  /// one that references a file it may come to hold, so the file is served to
  /// exactly the people the message reached. [own] adds the author's own
  /// callsign to a pair so the author can fetch back their own picture.
  void bindFromMessage(XprsPacket msg, {String? selfCallsign}) {
    final body = msg['m'] ?? '';
    if (body.isEmpty) return;
    final refs = MediaRef.findAll(body);
    if (refs.isEmpty) return;
    final d = _base(msg['d'] ?? '');
    final from = _base(msg['f'] ?? '');

    XprsFileScope scope;
    String? group;
    var members = const <String>[];
    if (d.isEmpty) {
      scope = XprsFileScope.public;
    } else if (XprsGroups.instance.known.contains(d)) {
      scope = XprsFileScope.group;
      group = d;
    } else {
      scope = XprsFileScope.pair;
      members = {
        from,
        d,
        if (selfCallsign != null) _base(selfCallsign),
      }.where((c) => c.isNotEmpty).toList();
    }
    for (final r in refs) {
      bind(r.sha256Hex, scope: scope, group: group, members: members);
    }
  }

  /// May [requester] fetch the bytes of [shaHex]?
  ///
  /// No binding → public by default (open). Public → anyone. Pair → one of the
  /// two participants. Group → a current member, decided by the same
  /// [XprsGroups.mayPost] the core uses to gate posting (fail-open when the
  /// roster cannot be verified, exactly as posting does).
  bool authorized(String shaHex, String requester) {
    final db = _db;
    final sha = shaHex.trim().toLowerCase();
    final who = _base(requester);
    if (db == null) return true; // no store yet: do not lock a bench out
    if (who.isEmpty) return false;
    try {
      final rows = db.select(
          'SELECT scope, grp, members FROM xprs_file_acl WHERE sha=? LIMIT 1',
          [sha]);
      if (rows.isEmpty) return true; // unbound hash is public
      final scope = rows.first['scope'] as String? ?? 'public';
      switch (scope) {
        case 'public':
          return true;
        case 'pair':
          final members = (rows.first['members'] as String? ?? '')
              .split(',')
              .map(_base)
              .toSet();
          return members.contains(who);
        case 'group':
          final grp = rows.first['grp'] as String? ?? '';
          return grp.isNotEmpty && XprsGroups.instance.mayPost(grp, who);
        default:
          return false;
      }
    } catch (_) {
      return false; // a store that errors denies a private fetch, never leaks
    }
  }

  /// The recorded scope of a hash, for tests and status. Null when unbound.
  XprsFileScope? scopeOf(String shaHex) {
    final db = _db;
    if (db == null) return null;
    try {
      final rows = db.select(
          'SELECT scope FROM xprs_file_acl WHERE sha=? LIMIT 1',
          [shaHex.trim().toLowerCase()]);
      if (rows.isEmpty) return null;
      return XprsFileScope.values
          .firstWhere((s) => s.name == rows.first['scope']);
    } catch (_) {
      return null;
    }
  }
}
