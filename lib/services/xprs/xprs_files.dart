/*
 * xprs_files — `cmd:file`: the XPRS ask in front of the bulk lane.
 *
 * XPRS.md section 25.2.2 draws the whole transfer, and only the middle third of
 * it was ever built:
 *
 *   -- advert channel (XPRS) ------------------------------------------------
 *   ->  t:command ... cmd:file file:<ref> [off:<qty>] sig:...
 *   <-  t:result  ... code:202 sig:...
 *   -- bulk lane (binary, one ATT write per frame; 4D 01 = session magic) ----
 *       FILE_OFFER / FILE_ACCEPT / CHUNK / WIN_ACK / FILE_DONE / FILE_OK
 *   -- advert channel again -------------------------------------------------
 *   <-  t:result  ... code:200 sig:...
 *
 * The bulk lane is `mesh_session.dart` (MSP) over a short auto-paired GATT
 * session, spooled by `mesh_bulk_spool.dart` — built, and measured at 27 kB/s
 * phone to phone (docs/mesh.md M2). The advert channel is XPRS. What was
 * missing, in the specification's own words (section 37), is "the XPRS ask in
 * front of them". This file is that ask, both ends of it.
 *
 * Two things it deliberately does NOT do:
 *  - It never carries bytes. A `cmd:file` is 250 bytes like every other packet;
 *    the payload goes on the bulk lane and nowhere near an advertisement.
 *  - It never hashes or copies the file. The holder already knows the digest —
 *    that is what was asked for — and the spool serves it from disk.
 *
 * The final `200` is a statement about CONTENT, not transmission: it is aired
 * only after the receiving station verified the bytes itself and sent FILE_OK.
 */
import 'dart:async';
import 'dart:io';

import '../../util/media_ref.dart';
import '../log_service.dart';
import '../mesh/mesh_bulk_spool.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_publisher.dart';
import 'xprs_vocab.dart';

/// A file this station holds, as the answer to a `file:` reference.
class XprsHeldFile {
  /// Absolute path. The spool reads it with seek+read and never copies it.
  final String path;

  /// Lowercase hex SHA-256 — already known and trusted by the holder.
  final String shaHex;
  final int size;
  final String name;
  final String ext;

  const XprsHeldFile({
    required this.path,
    required this.shaHex,
    required this.size,
    required this.name,
    required this.ext,
  });
}

/// The SHA-256 a `file:` value names, as lowercase hex.
///
/// Section 6.7 gives two forms and says a receiver accepts both: 43 base64url
/// characters, a dot and the type (what a sender emits), or the earlier 64
/// lowercase hex. The extension is advisory and never part of identity.
String? xprsFileSha(String? ref) {
  final v = (ref ?? '').trim();
  if (v.isEmpty) return null;
  final dot = v.lastIndexOf('.');
  final head = dot > 0 ? v.substring(0, dot) : v;
  if (head.length == 64 && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(head)) {
    return head.toLowerCase();
  }
  return MediaRef.b64uToHex(head);
}

/// The extension a `file:` value carries, or '' when it is a bare digest.
String xprsFileExt(String? ref) {
  final v = (ref ?? '').trim();
  final dot = v.lastIndexOf('.');
  if (dot <= 0 || dot == v.length - 1) return '';
  final e = v.substring(dot + 1).toLowerCase();
  return RegExp(r'^[a-z0-9]{1,18}$').hasMatch(e) ? e : '';
}

/// Serves `cmd:file` (section 25.2) for whatever the host says it holds.
class XprsFileServer {
  XprsFileServer._();
  static final XprsFileServer instance = XprsFileServer._();

  /// What do we hold for this digest? Null means "not held" — a `404`.
  ///
  /// Set by whoever owns files worth serving; the update mirror registers its
  /// channel directories. Several owners chain by wrapping.
  XprsHeldFile? Function(String shaHex)? resolver;

  /// Files pinned explicitly, by digest. Consulted before [resolver], so an
  /// operator (or a bench run) can offer one file without displacing whatever
  /// service owns the dynamic lookup.
  final Map<String, XprsHeldFile> _held = {};

  /// Offer [f] to anyone who asks for its digest, until [drop].
  void hold(XprsHeldFile f) => _held[f.shaHex.toLowerCase()] = f;
  bool drop(String shaHex) => _held.remove(shaHex.toLowerCase()) != null;
  List<XprsHeldFile> get pinned => _held.values.toList(growable: false);

  XprsHeldFile? _lookUp(String shaHex) =>
      _held[shaHex] ?? resolver?.call(shaHex);

  /// Largest file this station will offer a peer. A transfer is minutes of
  /// somebody's radio and battery (section 31.2), so there has to be a number;
  /// above it the answer is a polite `403` naming the size.
  int maxServeBytes = 256 * 1024 * 1024;

  int served = 0;
  int refused = 0;
  int notHeld = 0;

  /// Asks answered with `202`, by the identifier of the ask, so the closing
  /// `200` can quote the same `r:` after the receiver's FILE_OK. Bounded: a
  /// transfer that never completes must not pin a record forever.
  final Map<String, _Served> _inFlight = {};
  static const int _inFlightMax = 32;

  /// Handle one `cmd:file`. Returns the code aired, for the caller's logs.
  ///
  /// The caller has already done the work every command shares: it is for us,
  /// it is not a duplicate, its signature is not forged, and the requester is
  /// within budget. This decides only the file question.
  int onCommand(
    XprsPacket p, {
    required String selfBase,
    required String from,
    required String cmdId,
    required void Function(int code, {String? m}) air,
  }) {
    final shaHex = xprsFileSha(p['file']);
    if (shaHex == null) {
      air(400, m: 'file: must be a digest');
      return 400;
    }
    final held = _lookUp(shaHex);
    if (held == null) {
      notHeld++;
      air(404);
      return 404;
    }
    if (held.size > maxServeBytes) {
      refused++;
      // What `size:` on a description exists to prevent (section 6.7.1): say
      // why, so the asker does not simply try again.
      air(403, m: 'too large: ${held.size}B');
      return 403;
    }

    // `off:` resumes (section 25.2). We do not act on it here: the spool keeps
    // the receiver's offset and MSP's FILE_ACCEPT carries it, which is the
    // same resume the spec describes, decided by the side that knows.
    final ok = MeshBulkSpool.instance.enqueueFromFile(
      held.path,
      held.shaHex,
      held.size,
      target: from,
      origin: selfBase,
      name: held.name,
      ext: held.ext.isNotEmpty ? held.ext : xprsFileExt(p['file']),
    );
    if (!ok) {
      // Already queued for this peer is success, not failure: the transfer it
      // is waiting for is the one it just asked for.
      final already = MeshBulkSpool.instance.holds(held.shaHex);
      if (!already) {
        refused++;
        air(403, m: 'cannot spool');
        return 403;
      }
    }
    served++;
    if (_inFlight.length >= _inFlightMax) {
      _inFlight.remove(_inFlight.keys.first);
    }
    _inFlight[held.shaHex] = _Served(cmdId, from, selfBase);
    LogService.instance
        .add('XPRS: cmd:file ${held.name} (${held.size}B) -> $from (202)');
    air(202);
    return 202;
  }

  /// The peer verified the bytes and sent FILE_OK. Close the exchange with the
  /// `200` the spec makes conditional on exactly that.
  void noteHandedOver(String shaHex, String peer) {
    final s = _inFlight.remove(shaHex.toLowerCase());
    if (s == null) return;
    if (s.to.toUpperCase() != peer.toUpperCase()) return;
    final wire = 't:result f:${s.self} d:${s.to} '
        'ts:${xprsNowTs()} r:${s.cmdId} code:200';
    unawaited(XprsPublisher.instance.publishWire(wire));
    LogService.instance.add('XPRS: cmd:file to ${s.to} complete (200)');
  }

  Map<String, dynamic> statusJson() => {
        'served': served,
        'refused': refused,
        'notHeld': notHeld,
        'inFlight': _inFlight.length,
        'maxServeBytes': maxServeBytes,
        'resolver': resolver != null,
        'pinned': [
          for (final f in _held.values)
            {'sha': f.shaHex, 'name': f.name, 'size': f.size}
        ],
      };
}

class _Served {
  final String cmdId;
  final String to;
  final String self;
  _Served(this.cmdId, this.to, this.self);
}

/// Asks another station for a file by digest, and waits for the bytes.
///
/// Follows the shape XprsCatchup already proved: a directed ask, correlation by
/// the section-5 identifier the responder echoes as `r:`, one ask in flight per
/// peer, and every reply code meaning what section 25.1 says it means.
class XprsFileFetch {
  XprsFileFetch._();
  static final XprsFileFetch instance = XprsFileFetch._();

  /// Asks outstanding, by the identifier of the ask.
  final Map<String, _Ask> _pending = {};

  /// Waiters by digest, completed when the bytes land and verify.
  final Map<String, Completer<String?>> _waiting = {};

  /// Digests a holder has already answered `202` for: the ask is done its job
  /// and re-airing it would only take rotation slots from the transfer.
  final Set<String> _accepted = {};

  /// How often an unanswered ask goes back on the air. Just under the
  /// advertising period (60 s), so a re-air lands in a different window rather
  /// than the same one.
  static const Duration askEvery = Duration(seconds: 45);

  /// Where a caller wants its file put, by digest. Set at [fetch] time and
  /// honoured by [claimInbound] so the artifact never becomes a sqlite blob.
  final Map<String, String> _destDir = {};

  /// How long to wait for the bytes once a peer said `202`.
  ///
  /// The bulk lane moves ~27 kB/s and MSP ends a session politely at 300 s,
  /// resuming in the next one — so a large file legitimately spans several
  /// sessions and a generous ceiling is the honest number, not an optimistic
  /// one. The caller may pass its own.
  static const Duration defaultTimeout = Duration(minutes: 90);

  /// Ask [archiver] for the file named by [shaHex]; complete with the local
  /// path once it has arrived and verified, or null on any refusal or timeout.
  Future<String?> fetch({
    required String archiver,
    required String shaHex,
    required String selfCallsign,
    String ext = '',
    int off = 0,
    String? destDir,
    Duration timeout = defaultTimeout,
  }) async {
    final sha = shaHex.toLowerCase();
    final existing = _waiting[sha];
    if (existing != null) return existing.future;

    final ref = MediaRef.hexToB64u(sha);
    if (ref == null) return null;
    final b = StringBuffer('t:command f:$selfCallsign d:$archiver '
        'ts:${xprsNowTs()} cmd:file file:$ref');
    if (ext.isNotEmpty) b.write('.$ext');
    if (off > 0) b.write(' off:$off');
    final wire = b.toString();
    final p = XprsPacket.parse(wire);
    if (p == null || !p.fits) {
      LogService.instance.add('XPRS: cmd:file ask does not fit — not sent');
      return null;
    }
    final id = xprsIdentifier(p); // before signing, like every other ask
    final done = Completer<String?>();
    _waiting[sha] = done;
    if (destDir != null) _destDir[sha] = destDir;
    _pending[id] = _Ask(archiver, sha);

    LogService.instance.add('XPRS: asking $archiver for ${sha.substring(0, 8)}');
    await XprsPublisher.instance.publishWire(wire);

    // Re-air the ask until it is answered.
    //
    // The advert channel is fire-and-forget on a half-duplex radio: "a frame
    // transmitted once may not be observed at all" (docs/ble5.md section 1), and
    // the transmit window is five seconds a minute shared by every registered
    // frame. Asked once, a cmd:file is simply lost some of the time — measured
    // on the bench, the holder's `served` counter stayed at 0 for a whole
    // six-minute attempt. XprsCatchup re-asks on a cadence for the same reason.
    //
    // The SAME wire is re-published each time, so `ts:` and therefore the
    // section-5 identifier stay put and the answer still correlates; the advert
    // key is refreshed rather than a second frame added.
    final retry = Timer.periodic(askEvery, (t) {
      if (done.isCompleted || !_pending.containsKey(id)) {
        t.cancel();
        return;
      }
      if (_accepted.contains(sha)) return; // 202 in hand; bytes are coming
      unawaited(XprsPublisher.instance.publishWire(wire));
    });

    Timer(timeout, () {
      retry.cancel();
      if (done.isCompleted) return;
      _pending.remove(id);
      _waiting.remove(sha);
      _destDir.remove(sha);
      _accepted.remove(sha);
      LogService.instance
          .add('XPRS: cmd:file ${sha.substring(0, 8)} timed out');
      done.complete(null);
    });
    unawaited(done.future.whenComplete(retry.cancel));
    return done.future;
  }

  /// A `t:result` arrived. Chained after XprsCatchup's own handler.
  void onResult(XprsPacket p) {
    final ask = _pending[p['r'] ?? ''];
    if (ask == null) return;
    final code = int.tryParse(p['code'] ?? '') ?? 0;
    switch (code) {
      case 202:
        // Accepted; the bytes are coming on the bulk lane. Keep waiting — the
        // completion is FILE_OK on that lane, not this packet. Stop re-airing.
        _accepted.add(ask.sha);
        LogService.instance.add('XPRS: ${ask.station} accepted (202)');
        return;
      case 200:
        // The holder's closing receipt. The bytes themselves are what complete
        // the wait, via [noteInboundComplete]; if they already did, this is
        // just confirmation.
        _pending.remove(p['r']);
        return;
      case 404:
      case 403:
      case 429:
      case 400:
      case 500:
        _pending.remove(p['r']);
        final w = _waiting.remove(ask.sha);
        LogService.instance.add(
            'XPRS: ${ask.station} refused ${ask.sha.substring(0, 8)} ($code)'
            '${p.has('m') ? ' — ${p['m']}' : ''}');
        if (w != null && !w.isCompleted) w.complete(null);
        return;
      default:
        return;
    }
  }

  /// Claim an arriving file we asked for, before the spool archives it.
  ///
  /// Archiving reads the whole file into memory and stores it as a sqlite
  /// blob. For a 56 MB artifact that is the wrong answer on both counts, so a
  /// caller that named a destination gets a rename instead — same volume, no
  /// bytes moved (docs/performance.md 8.7).
  String? claimInbound(
      String shaHex, String partPath, Map<String, dynamic> meta) {
    final sha = shaHex.toLowerCase();
    final dir = _destDir[sha];
    if (dir == null || !_waiting.containsKey(sha)) return null;
    try {
      Directory(dir).createSync(recursive: true);
      final name = (meta['name'] as String?)?.trim();
      final base = (name == null || name.isEmpty) ? sha : name;
      final dest = '$dir${Platform.pathSeparator}$base';
      File(partPath).renameSync(dest);
      return dest;
    } catch (e) {
      LogService.instance.add('XPRS: claim of ${sha.substring(0, 8)} failed: $e');
      return null; // fall back to the archive path rather than lose the file
    }
  }

  /// The bulk lane finished and the file verified against its digest.
  void noteInboundComplete(String shaHex, String path) {
    _destDir.remove(shaHex.toLowerCase());
    _accepted.remove(shaHex.toLowerCase());
    final w = _waiting.remove(shaHex.toLowerCase());
    _pending.removeWhere((_, a) => a.sha == shaHex.toLowerCase());
    if (w == null || w.isCompleted) return;
    LogService.instance
        .add('XPRS: ${shaHex.substring(0, 8)} arrived over the bulk lane');
    w.complete(path);
  }

  bool get busy => _waiting.isNotEmpty;

  Map<String, dynamic> statusJson() => {
        'pending': _pending.length,
        'waiting': [for (final s in _waiting.keys) s.substring(0, 8)],
      };
}

class _Ask {
  final String station;
  final String sha;
  _Ask(this.station, this.sha);
}
