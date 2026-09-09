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
    // WHAT OPENED A MESSAGE FROM WHOM. A tap used to try every remembered
    // passphrase in turn, each one a full 100000-iteration derivation, so the
    // reader paid for the whole list to open one message (§6.2.1 prices ONE
    // derivation per message per passphrase tried; the sweep was ours). A
    // passphrase is almost always a property of who you share it with, so the
    // one that last worked for a sender is the one to try first.
    db.execute('''
      CREATE TABLE IF NOT EXISTS xprs_pass_hint(
        peer TEXT PRIMARY KEY,
        pass TEXT NOT NULL,
        used INTEGER NOT NULL
      )''');
    // A message ALREADY OPENED, by §5 id. Re-deriving to show the reader
    // something they have already been shown buys nothing: §6.2.1's cost is
    // there so "a bot [cannot harvest] a thousand redacted email addresses for
    // free", not to charge the holder of the passphrase twice for one message.
    //
    // The plaintext is no more exposed than it already was: the passphrase
    // that opens it is kept in THIS SAME SQLCipher database, so anyone who can
    // read this table could decrypt the message anyway, and content opened
    // with the default passphrase is public by construction. The tap is
    // untouched -- a reopened conversation still shows bars.
    db.execute('''
      CREATE TABLE IF NOT EXISTS xprs_redacted_in(
        id   TEXT PRIMARY KEY,
        text TEXT NOT NULL,
        pass TEXT NOT NULL,
        ts   INTEGER NOT NULL
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

  /// Bumped whenever the set of passphrases this station knows CHANGES.
  ///
  /// The expensive case is a message nothing opens: it costs the whole list,
  /// every tap, forever. Remembering that miss is only safe while the answer
  /// cannot have changed, and the only thing that changes it is a new (or
  /// forgotten) passphrase -- so a miss is recorded against this number and
  /// believed only while it holds (docs/performance.md §3.2, cache the miss).
  int generation = 0;

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
    generation++;
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

  /// Note that [pass] opened a message from [peer], so the next message from
  /// them tries it first. Peers are callsigns; the default passphrase is not
  /// worth a hint (it is tried early for everyone anyway).
  void hint(String peer, String pass, {int? nowMs}) {
    final db = _db;
    final p = peer.trim().toUpperCase();
    if (db == null || p.isEmpty || pass.isEmpty) return;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    try {
      db.execute(
        'INSERT INTO xprs_pass_hint(peer, pass, used) VALUES(?, ?, ?) '
        'ON CONFLICT(peer) DO UPDATE SET pass = excluded.pass, used = excluded.used',
        [p, pass, now],
      );
    } catch (_) {}
  }

  /// What last opened a message from [peer], or null.
  String? hintFor(String peer) {
    final db = _db;
    final p = peer.trim().toUpperCase();
    if (db == null || p.isEmpty) return null;
    try {
      final rows = db.select(
          'SELECT pass FROM xprs_pass_hint WHERE peer = ? LIMIT 1', [p]);
      return rows.isEmpty ? null : rows.first['pass'] as String;
    } catch (_) {
      return null;
    }
  }

  /// Keep the plaintext of a message this reader has already opened, by §5 id.
  void cacheOpened(String id, String text, String pass, {int? nowMs}) {
    final db = _db;
    if (db == null || id.isEmpty) return;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    try {
      db.execute(
        'INSERT INTO xprs_redacted_in(id, text, pass, ts) VALUES(?, ?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET text = excluded.text, '
        'pass = excluded.pass, ts = excluded.ts',
        [id, text, pass, now],
      );
    } catch (_) {}
  }

  /// The plaintext of an already-opened message, or null. A hit costs no
  /// derivation at all.
  String? opened(String id) {
    final db = _db;
    if (db == null || id.isEmpty) return null;
    try {
      final rows = db.select(
          'SELECT text FROM xprs_redacted_in WHERE id = ? LIMIT 1', [id]);
      return rows.isEmpty ? null : rows.first['text'] as String;
    } catch (_) {
      return null;
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
  ///
  /// Everything it opened goes with it: a cached plaintext outliving the key
  /// that produced it would make "forget" a lie.
  void forget(String pass) {
    generation++;
    try {
      _db?.execute('DELETE FROM xprs_passphrases WHERE pass = ?', [pass]);
      _db?.execute('DELETE FROM xprs_redacted_in WHERE pass = ?', [pass]);
      _db?.execute('DELETE FROM xprs_pass_hint WHERE pass = ?', [pass]);
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
