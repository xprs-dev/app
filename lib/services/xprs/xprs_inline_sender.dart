/*
 * xprs_inline_sender — the sending half of the packet-lane file transfer
 * (XPRS.md 7.7.6), in the core, on the one send path.
 *
 * A small file is split into `t:file` chunks and each chunk goes out as ONE
 * packet with no bookkeeping (XprsBearer.send `datagram`): no link handshake,
 * no retry ladder, no custody, no chat row. The chunks are paced, since the
 * uplink buffers without bound and a burst is what a hub's budget punishes.
 * Loss is the receiver's to report: after a moment of silence it sends
 * `cmd:file ... have:<map>` (section 8.1's bitfield) and [onHave] re-sends
 * only what the map lacks, from the same deterministic split.
 *
 * Measured before this existed: fifty-one chunks, each awaiting a fresh link
 * and leaving a retry entry, a custody parking and a chat row behind, took
 * thirty-eight minutes. The chunks were never the slow part.
 *
 * The bytes are kept where every other file this station authored is kept,
 * the media archive ([store]), so a re-send months later is answered like any
 * `cmd:file`: the station self-hosts what it sent.
 */
import 'dart:async';
import 'dart:typed_data';

import '../log_service.dart';
import 'xprs_inline_file.dart';
import 'xprs_publisher.dart';

class XprsInlineSender {
  XprsInlineSender._();
  static final XprsInlineSender instance = XprsInlineSender._();

  /// Store the bytes locally (media archive + audience binding), returning the
  /// `file:` token or null. Set by the core (mesh_service); a sender that
  /// cannot store still sends, it just cannot answer a re-ask.
  String? Function(Uint8List bytes, String ext, String to)? store;

  /// Between chunks. About twelve packets a second: a 32 kB file in under
  /// half a minute, and no burst for a hub to throttle.
  Duration gap = const Duration(milliseconds: 80);

  int sent = 0;
  int refused = 0;
  int resent = 0;

  /// Chunks that took over 300 ms to hand to the bearer. Measured before the
  /// curve was taken off the per-packet path: every one of them, 5 to 28 s.
  int slowChunks = 0;

  final List<_Job> _queue = [];
  bool _draining = false;

  /// Split, store, and queue [bytes] for [to]. Returns the `file:` ref the
  /// chunks carry, or null when the lane will not carry it (empty, over the
  /// cap, or callsigns too long to leave room for a chunk).
  String? send(Uint8List bytes,
      {required String from, required String to, required String ext}) {
    final wires = xprsInlineSplit(bytes, from: from, to: to, ext: ext);
    if (wires.isEmpty) return null;
    store?.call(bytes, ext, to);
    final ref = _refOf(wires.first);
    _queue.add(_Job(to, wires));
    unawaited(_drain());
    LogService.instance.add(
        'XPRS: inline ${bytes.length} B -> $to as ${wires.length} packets');
    return ref;
  }

  /// A receiver said what it holds of [bytes] (its `have:` map); re-send the
  /// rest. Returns how many chunks were queued (0 = nothing missing).
  int onHave(Uint8List bytes,
      {required String from,
      required String to,
      required String ext,
      required String have}) {
    final wires = xprsInlineSplit(bytes, from: from, to: to, ext: ext);
    if (wires.isEmpty) return 0;
    final held = xprsInlineHaveDecode(have, wires.length);
    if (held == null) return 0;
    final missing = <String>[
      for (var k = 0; k < wires.length; k++)
        if (!held.contains(k)) wires[k],
    ];
    if (missing.isEmpty) return 0;
    resent += missing.length;
    _queue.add(_Job(to, missing));
    unawaited(_drain());
    LogService.instance.add('XPRS: inline re-send ${missing.length} of '
        '${wires.length} chunks -> $to');
    return missing.length;
  }

  /// A chunk the bearer refused (no path this instant) is tried again after
  /// [retryAfter], up to [maxAttempts] passes, before the receiver's own report
  /// is the only thing left to bring it. A path over public hubs comes and
  /// goes; measured: 144 refusals in one transfer while the route flapped.
  Duration retryAfter = const Duration(seconds: 2);
  static const int maxAttempts = 6;

  Future<void> _drain() async {
    if (_draining) return;
    _draining = true;
    try {
      while (_queue.isNotEmpty) {
        final job = _queue.removeAt(0);
        // Only the lanes that reach the peer, decided by the publisher; a
        // packet meant for one station is not spent on the shared advert
        // channel it cannot be heard on.
        final lanes = XprsPublisher.instance.reachableLanes(job.to);
        final only = lanes.isEmpty ? null : lanes;
        final again = <String>[];
        for (final w in job.wires) {
          final sw = Stopwatch()..start();
          final rep = await XprsPublisher.instance
              .publishWire(w, onlyBearers: only, datagram: true);
          // Counted, not logged (performance.md 8.10): a slow phone made
          // every chunk slow, and a line per chunk buried the answer.
          if (sw.elapsedMilliseconds > 300) slowChunks++;
          if (rep.values.any((v) => v == 'sent' || v == 'queued')) {
            sent++;
          } else {
            refused++;
            again.add(w);
          }
          await Future<void>.delayed(gap);
        }
        if (again.isNotEmpty && job.attempt + 1 < maxAttempts) {
          LogService.instance.add('XPRS: inline ${again.length} chunk(s) '
              'refused -> ${job.to}; pass ${job.attempt + 2} in '
              '${retryAfter.inSeconds}s');
          await Future<void>.delayed(retryAfter);
          _queue.add(_Job(job.to, again, attempt: job.attempt + 1));
        }
      }
    } finally {
      _draining = false;
    }
  }

  static String _refOf(String wire) {
    final i = wire.indexOf(' file:');
    if (i < 0) return '';
    final j = wire.indexOf(' ', i + 6);
    return wire.substring(i + 6, j < 0 ? wire.length : j);
  }

  int get queued => _queue.fold(0, (n, j) => n + j.wires.length);
}

class _Job {
  _Job(this.to, this.wires, {this.attempt = 0});
  final String to;
  final List<String> wires;
  final int attempt;
}
