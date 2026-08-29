/*
 * The groups this station administers -- their keys (docs/XPRS.md section 26).
 *
 * "A closed group holds a keypair, so it gets a callsign like anything else.
 * The admin is whoever holds the matching private key. THAT KEY BELONGS TO THE
 * GROUP, NOT TO THE PERSON, which is the property everything else in this
 * section rests on: an admin hands the group on by handing over the group's
 * key, and never has to share the private key of their own callsign to do it."
 *
 * So this is a second key store, deliberately separate from the profile's own
 * nsec. `xprsProfileScalar()` is documented as the one implementation of "which
 * key signs XPRS", and it stays that -- for the STATION. A group signs as
 * itself, and [scalarFor] is that key.
 *
 * It lives in the profile database, which is SQLCipher-encrypted, because a
 * group's private key is exactly as sensitive as the profile's own: section
 * 26.6 says a leaked one is permanent, cannot be rotated (the callsign derives
 * from it), and its holder is indistinguishable from the admin.
 */
import 'package:hex/hex.dart';
import 'package:sqlite3/common.dart';

import '../../profile/profile_db.dart';
import '../../util/nostr_crypto.dart';

/// A group this station holds the key for.
class XprsOwnGroup {
  const XprsOwnGroup(this.callsign, this.npub, this.nick, this.createdMs);

  /// The `X5` callsign, derived from the key (section 26.1).
  final String callsign;
  final String npub;

  /// The readable name `t:identity` carries in `nick:`, shown only when the
  /// signature verifies (section 9.3.1).
  final String nick;
  final int createdMs;
}

class XprsGroupKeys {
  XprsGroupKeys._();
  static final XprsGroupKeys instance = XprsGroupKeys._();

  CommonDatabase? _db;

  bool get ready => _db != null;

  void init(String path) {
    close();
    final db = openProfileDb(path);
    db.execute('''
      CREATE TABLE IF NOT EXISTS xprs_groups(
        callsign TEXT PRIMARY KEY,
        npub     TEXT NOT NULL,
        nsec     TEXT NOT NULL,
        nick     TEXT NOT NULL DEFAULT '',
        created  INTEGER NOT NULL
      )''');
    _db = db;
  }

  void close() {
    try {
      _db?.dispose();
    } catch (_) {
      // A store that will not close must not stop the next profile opening.
    }
    _db = null;
  }

  /// Mint a group: a keypair, and the `X5` callsign that key produces.
  ///
  /// There is no registry and no creation ceremony (26.1) -- a group "exists
  /// once somebody generates a key and says so", and saying so is the
  /// `t:identity` the caller airs next.
  XprsOwnGroup? create({String nick = ''}) {
    final db = _db;
    if (db == null) return null;
    final kp = NostrCrypto.generateKeyPair();
    final call = 'X5${NostrCrypto.deriveCallsign(kp.publicKeyHex)}';
    final now = DateTime.now().millisecondsSinceEpoch;
    // A collision means somebody already holds a group whose key produced
    // these characters. Section 26.1: the group is its full public key, and
    // two groups wearing the same characters are two groups -- but this
    // station cannot hold both under one id, so try again for a new key.
    if (db.select('SELECT 1 FROM xprs_groups WHERE callsign = ?', [call])
        .isNotEmpty) {
      return null;
    }
    db.execute(
        'INSERT INTO xprs_groups(callsign, npub, nsec, nick, created) '
        'VALUES(?,?,?,?,?)',
        [call, kp.npub, kp.nsec, nick.trim(), now]);
    return XprsOwnGroup(call, kp.npub, nick.trim(), now);
  }

  /// The private scalar this group signs with, or null when we do not hold it
  /// -- i.e. we are a member or a bystander rather than the admin.
  BigInt? scalarFor(String callsign) {
    final db = _db;
    if (db == null) return null;
    final rows = db.select('SELECT nsec FROM xprs_groups WHERE callsign = ?',
        [callsign.trim().toUpperCase()]);
    if (rows.isEmpty) return null;
    try {
      var d = BigInt.zero;
      for (final b in HEX.decode(NostrCrypto.decodeNsec(
          (rows.first['nsec'] ?? '').toString()))) {
        d = (d << 8) | BigInt.from(b);
      }
      return d;
    } catch (_) {
      return null;
    }
  }

  /// The npub for a group we hold, so its `t:identity` can carry `k:`.
  String? npubFor(String callsign) {
    final rows = _db?.select(
        'SELECT npub FROM xprs_groups WHERE callsign = ?',
        [callsign.trim().toUpperCase()]);
    if (rows == null || rows.isEmpty) return null;
    return (rows.first['npub'] ?? '').toString();
  }

  /// Every group this station administers.
  List<XprsOwnGroup> mine() {
    final rows = _db?.select(
        'SELECT callsign, npub, nick, created FROM xprs_groups '
        'ORDER BY created DESC');
    if (rows == null) return const [];
    return [
      for (final r in rows)
        XprsOwnGroup(
          (r['callsign'] ?? '').toString(),
          (r['npub'] ?? '').toString(),
          (r['nick'] ?? '').toString(),
          (r['created'] as int?) ?? 0,
        )
    ];
  }

  /// Hand the group on: section 26.6's succession is handing over the key, and
  /// dropping our copy is the half of that we can actually do. The previous
  /// holder keeping a copy is named there as a cost with no protocol answer.
  bool forget(String callsign) {
    final db = _db;
    if (db == null) return false;
    db.execute('DELETE FROM xprs_groups WHERE callsign = ?',
        [callsign.trim().toUpperCase()]);
    return true;
  }
}
