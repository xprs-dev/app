/*
 * The passphrases this station has used to open redacted text (docs/XPRS.md
 * section 9.2.1, the `xr:` field).
 *
 * A redacted message shows bars until the reader taps it; the tap asks the core
 * to open it, and the core tries the passphrases kept HERE (plus the default
 * `################`) before it asks the reader for a new one. A passphrase that
 * opens a message is remembered, so the next redacted message from anyone using
 * the same secret opens without a prompt. The reader still taps every time --
 * persistence only removes the prompt, never the tap.
 *
 * It lives in the profile database, which is SQLCipher-encrypted: a remembered
 * passphrase is a small secret and belongs with the profile's own, like a
 * password manager's store. Section 9.2.1 is plain that the default passphrase
 * buys obfuscation not secrecy, but a real one a reader typed is worth keeping
 * out of the clear. Mirrors [XprsGroupKeys]'s per-profile store.
 */
import 'package:sqlite3/common.dart';

import '../../profile/profile_db.dart';

class XprsPassphrases {
  XprsPassphrases._();
  static final XprsPassphrases instance = XprsPassphrases._();

  CommonDatabase? _db;

  bool get ready => _db != null;

  void init(String path) {
    close();
    final db = openProfileDb(path);
    db.execute('''
      CREATE TABLE IF NOT EXISTS xprs_passphrases(
        pass  TEXT PRIMARY KEY,
        ts    INTEGER NOT NULL,
        used  INTEGER NOT NULL,
        count INTEGER NOT NULL DEFAULT 0
      )''');
    // The author's OWN composed redacted messages, kept by §5 id so the author
    // can open their own bubble (9.2.1). The core airs a post over whatever
    // bearer carries it -- BLE, LoRa, the local network, Reticulum -- and only
    // archives its own send once a bearer took it; with none available yet
    // (nothing in range) there is no archived copy to reveal from. This is that
    // copy, independent of any bearer. Ciphertext only (the `xr:` blob + bars),
    // never plaintext.
    db.execute('''
      CREATE TABLE IF NOT EXISTS xprs_redacted_out(
        id   TEXT PRIMARY KEY,
        wire TEXT NOT NULL
      )''');
    // `count` (how many times this passphrase has opened a message) was added
    // after the table; ALTER for older stores, ignoring the duplicate-column
    // error on one that already has it.
    try {
      db.execute(
          'ALTER TABLE xprs_passphrases ADD COLUMN count INTEGER NOT NULL DEFAULT 0');
    } catch (_) {}
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

  /// Remember a passphrase that just opened a message, or bump its recency if
  /// already known. The default passphrase is never stored -- it is always
  /// tried anyway, and storing it would only push a real one down the list.
  void remember(String pass, {int? nowMs}) {
    final db = _db;
    if (db == null || pass.isEmpty) return;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    try {
      db.execute(
        'INSERT INTO xprs_passphrases(pass, ts, used, count) VALUES(?, ?, ?, 1) '
        'ON CONFLICT(pass) DO UPDATE SET used = excluded.used, count = count + 1',
        [pass, now, now],
      );
    } catch (_) {
      // A write that fails just means one fewer remembered passphrase.
    }
  }

  /// Every remembered passphrase, MOST-USED first and most-recently-used to
  /// break ties -- the order the compose picker shows and the unlock auto-try
  /// walks, so the likeliest key comes first.
  List<String> all() {
    final db = _db;
    if (db == null) return const [];
    try {
      final rows =
          db.select('SELECT pass FROM xprs_passphrases ORDER BY count DESC, used DESC LIMIT 200');
      return [for (final r in rows) r['pass'] as String];
    } catch (_) {
      return const [];
    }
  }

  /// Forget a passphrase (a reader clearing a wrong one they saved by mistake).
  void forget(String pass) {
    try {
      _db?.execute('DELETE FROM xprs_passphrases WHERE pass = ?', [pass]);
    } catch (_) {}
  }

  /// Keep the wire of a redacted message this station composed, by §5 id, so its
  /// author can open their own bubble even before any bearer has carried it (a
  /// post the core has not yet archived because nothing was in range). It is the
  /// same barred wire every recipient sees -- ciphertext and bars, no plaintext.
  void rememberRedaction(String id, String wire) {
    if (id.isEmpty || wire.isEmpty) return;
    try {
      _db?.execute(
        'INSERT INTO xprs_redacted_out(id, wire) VALUES(?, ?) '
        'ON CONFLICT(id) DO UPDATE SET wire = excluded.wire',
        [id, wire],
      );
    } catch (_) {}
  }

  /// The wire of an own composed redacted message, or null.
  String? redactionWire(String id) {
    final db = _db;
    if (db == null || id.isEmpty) return null;
    try {
      final rows = db.select(
          'SELECT wire FROM xprs_redacted_out WHERE id = ? LIMIT 1', [id]);
      return rows.isEmpty ? null : rows.first['wire'] as String;
    } catch (_) {
      return null;
    }
  }
}
