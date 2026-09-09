/*
 * Hidden text (XPRS.md 6.2.1): opening one, and airing one.
 *
 * A message may hide PARTS of itself -- `((secret))` becomes a run of █ bars
 * on the wire and the pieces travel encrypted in `xr:`. The reader taps a
 * barred bubble and this decides what to try, what it already knows, and what
 * to remember; the author marks a message and this builds the bars, the blob
 * and the packet.
 *
 * IT IS A CORE CAPABILITY, NOT A CHAT ONE. Any wapp reaches it through
 * `hal_xprs_unlock` / `hal_xprs_redact`, and the HTTP API could reach it too;
 * nothing here knows a wapp exists (docs/architecture.md §3). It used to live
 * inside `wapp_engine.dart` -- the wapp BRIDGE -- which put a key, a database
 * and a cipher in the layer whose one job is passing calls across the wasm
 * boundary.
 *
 * WHAT COSTS WHAT. 6.2.1 fixes the price of reading one at
 * PBKDF2-HMAC-SHA256, 100000 iterations, per message per passphrase tried,
 * and says why: "the derivation is the strength, and it costs everyone the
 * same per message ... ruin at scale for a harvester or a brute-forcer". That
 * price is not touched here, and must not be. What IS ours, and was being paid
 * needlessly:
 *
 *   - the whole remembered list, in order of popularity, on every tap. Up to
 *     201 derivations to open one message. Now: what last worked for that
 *     sender, then the default, then the rest.
 *   - the same message, again, every time it is tapped. Now: a message this
 *     reader has already opened is answered from the profile database.
 *   - a message nothing opens, re-swept on every tap. Now: the miss is
 *     remembered until the set of known passphrases changes.
 *
 * The tap itself is untouched. A reopened conversation still shows bars; only
 * the wait goes away, never the asking.
 */
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:reticulum/reticulum.dart' show XprsCrypto;

import '../../wapp/wapp_event_broker.dart';
import '../log_service.dart';
import '../mesh/mesh_service.dart';
import 'xprs_archive.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_passphrases.dart';
import 'xprs_publisher.dart';
import 'xprs_vocab.dart';

class XprsRedaction {
  XprsRedaction._();
  static final XprsRedaction instance = XprsRedaction._();

  /// Derivations actually paid, and the taps that cost none. Counters rather
  /// than a clock, so a test can assert the SHAPE of the work and a phone can
  /// report the truth (docs/performance.md §4: measured, not assumed).
  static int derivations = 0;
  static int cacheHits = 0;
  static int missSkips = 0;

  /// Messages no known passphrase opened, against the passphrase-store
  /// generation at the time. In memory: a restart may re-sweep once, which is
  /// cheap and self-correcting, and nothing is served from it -- it only
  /// SKIPS work that is known to be pointless.
  final Map<String, int> _missAt = {};

  @visibleForTesting
  void resetForTest() {
    _missAt.clear();
    derivations = 0;
    cacheHits = 0;
    missSkips = 0;
  }

  /// Open a redacted message by its §5 identifier and announce the result on
  /// `xprs.unlock` as `{id, ok, text}`.
  ///
  /// [pass] empty means "use what this station knows"; non-empty is a
  /// passphrase the reader just typed, and is tried alone.
  Future<void> open(String id, String pass) async {
    final sw = Stopwatch()..start();
    final before = derivations;
    final row = await _open(id, pass);
    sw.stop();
    // The one line that says whether a slow tap was the spec's price or ours.
    // Never the text: /api/log is served over the LAN (docs/performance.md
    // §8.10), and the whole point of this field is that the words are hidden.
    LogService.instance.add('xr: open $id ${row['ok'] == true ? 'ok' : 'no'} '
        'in ${sw.elapsedMilliseconds}ms, ${derivations - before} derivation(s)');
    WappEventBroker.instance.publish('core', 'xprs.unlock', jsonEncode(row));
  }

  Future<Map<String, dynamic>> _open(String id, String pass) async {
    // Already open: no derivation, no isolate, no wait. Only for the ordinary
    // tap -- a reader who typed a passphrase is answering a prompt and means
    // to try THAT one.
    if (pass.isEmpty) {
      final had = XprsPassphrases.instance.opened(id);
      if (had != null && had.isNotEmpty) {
        cacheHits++;
        return {'id': id, 'ok': true, 'text': had};
      }
    }

    final wire = _wireOf(id);
    if (wire == null || wire.isEmpty) return {'id': id, 'ok': false};

    // Nothing we know opens it, and nothing has been learned since we last
    // found that out. Re-deriving the same list against the same message
    // cannot answer differently.
    final gen = XprsPassphrases.instance.generation;
    if (pass.isEmpty && _missAt[id] == gen) {
      missSkips++;
      return {'id': id, 'ok': false};
    }

    final passes = pass.isNotEmpty
        ? <String>[pass]
        : candidates(_senderOf(wire));
    final res = await compute(
        xrUnlockCompute, <String, dynamic>{'wire': wire, 'passes': passes});
    if (res.isEmpty) {
      derivations += passes.length; // every candidate was paid for in full
      if (pass.isEmpty) _missAt[id] = gen;
      return {'id': id, 'ok': false};
    }

    final m = jsonDecode(res) as Map<String, dynamic>;
    final okPass = m['pass'] as String? ?? '';
    final text = (m['text'] ?? '').toString();
    derivations += passes.indexOf(okPass) + 1;
    _missAt.remove(id);

    // Remember only a passphrase the reader just typed that worked -- never
    // the default, and stored ones are already kept.
    if (pass.isNotEmpty && okPass != XprsCrypto.kXrDefaultPassphrase) {
      XprsPassphrases.instance.remember(okPass);
    }
    // Whoever sent it uses this passphrase: try it first for them next time.
    final peer = _senderOf(wire);
    if (peer.isNotEmpty && okPass != XprsCrypto.kXrDefaultPassphrase) {
      XprsPassphrases.instance.hint(peer, okPass);
    }
    XprsPassphrases.instance.cacheOpened(id, text, okPass);
    return {'id': id, 'ok': true, 'text': text};
  }

  /// The passphrases to try, in the order that pays for the fewest.
  ///
  /// 1. what last opened a message from this sender -- a passphrase is a
  ///    property of who you share it with;
  /// 2. the default, which 6.2.1 makes the common case and which is public
  ///    anyway, so trying it early costs nobody anything;
  /// 3. everything else, most-used first, as before.
  @visibleForTesting
  List<String> candidates(String peer) {
    final out = <String>[];
    final hint = peer.isEmpty ? null : XprsPassphrases.instance.hintFor(peer);
    if (hint != null && hint.isNotEmpty) out.add(hint);
    if (!out.contains(XprsCrypto.kXrDefaultPassphrase)) {
      out.add(XprsCrypto.kXrDefaultPassphrase);
    }
    for (final p in XprsPassphrases.instance.all()) {
      if (!out.contains(p)) out.add(p);
    }
    return out;
  }

  /// The wire of a redacted message: the archive, or -- for a post of our own
  /// that no bearer has carried yet -- the copy kept when it was composed.
  String? _wireOf(String id) {
    var wire = XprsArchive.instance.wireById(id);
    if (wire == null || wire.isEmpty) {
      // It may be staged in the archive but not yet flushed to disk (a message
      // just heard). Flush and look again.
      XprsArchive.instance.flush();
      wire = XprsArchive.instance.wireById(id);
    }
    if (wire == null || wire.isEmpty) {
      wire = XprsPassphrases.instance.redactionWire(id);
    }
    return wire;
  }

  static String _senderOf(String wire) =>
      (XprsPacket.parse(wire)?['f'] ?? '').trim().toUpperCase();

  // ── Airing one ────────────────────────────────────────────────────────

  /// Air [text] with its `((...))` spans hidden, and echo the author's own
  /// barred copy on `xprs.redacted` as `{convo, id, m, ok}`.
  ///
  /// [convo] is where it goes: `#LOCAL` is the undirected room, anything else
  /// is a callsign or `#` + a group's X5 callsign. [pass] empty = the default.
  Future<void> hide(String convo, String text, String pass) async {
    final passphrase = pass.isEmpty ? XprsCrypto.kXrDefaultPassphrase : pass;
    final res = await compute(xrRedactCompute,
        <String, dynamic>{'text': text, 'passphrase': passphrase});
    if (res.isEmpty) return _failed(convo); // nothing was marked
    final m = jsonDecode(res) as Map<String, dynamic>;
    final barred = m['barred'] as String;
    final xr = m['xr'] as String;
    final self = MeshService.instance.tableCallsign.trim();
    if (self.isEmpty) return _failed(convo);

    final wire = redactedWire(
        self: self, convo: convo, ts: xprsNowTs(), xr: xr, barred: barred);
    final p = XprsPacket.parse(wire);
    if (p == null || !p.fits) return _failed(convo);
    if (!XprsPublisher.instance.mayAir(p)) return _failed(convo);

    if (pass.isNotEmpty) XprsPassphrases.instance.remember(pass);
    final id = xprsIdentifier(p);
    // Keep our own barred wire so we can open our own bubble later. The core
    // airs a post over whatever bearer carries it (BLE, LoRa, LAN, Reticulum)
    // and archives its own send only once a bearer took it; nothing in range
    // means no archived copy yet, so keep this one, bearer-independent.
    XprsPassphrases.instance.rememberRedaction(id, wire);
    // We wrote it, so we know what it says: opening our own bubble should
    // never cost a derivation.
    XprsPassphrases.instance.cacheOpened(id, plainOf(text), passphrase);
    unawaited(XprsPublisher.instance.publishWire(wire));
    WappEventBroker.instance.publish('core', 'xprs.redacted',
        jsonEncode({'convo': convo, 'id': id, 'm': barred, 'ok': true}));
  }

  /// Tell the wapp its redaction did not go out. Every refusal here used to
  /// end in a bare `return`: no packet, no bubble, and nothing said -- which
  /// looks exactly like a feature that does not work.
  void _failed(String convo) => WappEventBroker.instance.publish(
      'core', 'xprs.redacted', jsonEncode({'convo': convo, 'ok': false}));

  /// The authored text with its `((` `))` marks taken out -- what the author
  /// typed, and what `restore` would hand back to anyone with the passphrase.
  ///
  /// It walks the marks exactly as [XprsCrypto.redact] does (first `))` after
  /// each `((`, an unclosed `((` left verbatim) rather than deleting every
  /// bracket, so the author's own bubble cannot disagree with what the
  /// recipients read.
  @visibleForTesting
  static String plainOf(String authored) {
    final out = StringBuffer();
    var i = 0;
    while (i < authored.length) {
      final open = authored.indexOf('((', i);
      if (open < 0) {
        out.write(authored.substring(i));
        break;
      }
      final close = authored.indexOf('))', open + 2);
      if (close < 0) {
        out.write(authored.substring(i));
        break;
      }
      out.write(authored.substring(i, open));
      out.write(authored.substring(open + 2, close));
      i = close + 2;
    }
    return out.toString();
  }

  /// The wire a redacted post travels as.
  ///
  /// `#LOCAL` is the undirected room: it becomes a scoped broadcast
  /// (§13.11.1) with no `d:`, not an addressed packet. Anything else is a
  /// station's callsign, or `#` + a group's X5 callsign. `m:` is last by
  /// grammar and `xr:` precedes it, as in the §6.2.1 worked packet.
  @visibleForTesting
  static String redactedWire({
    required String self,
    required String convo,
    required String ts,
    required String xr,
    required String barred,
  }) {
    final room = convo.trim();
    if (room.toUpperCase() == '#LOCAL') {
      return 't:message f:$self ts:$ts scope:local xr:$xr m:$barred';
    }
    final dest = room.startsWith('#') ? room.substring(1) : room;
    return 't:message f:$self d:$dest ts:$ts xr:$xr m:$barred';
  }
}

// ── §6.2.1 crypto, run off the UI isolate via compute ───────────────────────
//
// Top-level so `compute` can spawn them. Pure functions over primitives: no
// database, no service state — the caller does the archive read and the
// passphrase store, these only derive keys and cipher, which is the part that
// may exceed a few milliseconds (architecture §2).

/// Try each passphrase against a redacted packet's whole wire; on the first that
/// opens it (the `->` sentinel), return the restored MESSAGE body as
/// `{"text":..,"pass":..}` JSON. Empty string = none opened it.
@visibleForTesting
String xrUnlockCompute(Map<String, dynamic> args) {
  final wire = args['wire'] as String;
  final passes = (args['passes'] as List).cast<String>();
  final p = XprsPacket.parse(wire);
  final xr = p?['xr'] ?? '';
  if (xr.isEmpty) return '';
  for (final pass in passes) {
    final restoredWire = XprsCrypto.restore(wire, xr, pass);
    if (restoredWire == null) continue;
    final rp = XprsPacket.parse(restoredWire);
    return jsonEncode({'text': rp?['m'] ?? '', 'pass': pass});
  }
  return '';
}

/// Redact the ((...)) spans in [text] with [passphrase]; return
/// `{"barred":..,"xr":..}` JSON, or empty string when nothing was marked.
@visibleForTesting
String xrRedactCompute(Map<String, dynamic> args) {
  final text = args['text'] as String;
  final passphrase = args['passphrase'] as String;
  final red = XprsCrypto.redact(text, passphrase: passphrase);
  if (red == null) return '';
  return jsonEncode({'barred': red.$1, 'xr': red.$2});
}
