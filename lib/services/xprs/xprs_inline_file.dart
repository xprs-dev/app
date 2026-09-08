/*
 * xprs_inline_file — a small binary carried by ordinary 250-byte XPRS packets
 * (XPRS.md §7.7.6), for the transport that passes text but blocks the bulk
 * lane: a public Reticulum hub cross-forwards directed messages and drops
 * binary links/resources, so the GATT/RNS-resource byte lane never completes.
 * A meme or a thumbnail then has one vehicle left — the packet itself.
 *
 * §7.7.4 already puts a file INLINE as `b:` base64 split with `n:X/Y`, but that
 * grammar allows at most nine parts (§4.3 ratio is 1..9), so it tops out at
 * 896 bytes. Above that and up to a modest cap this lane chunks the RAW bytes
 * by offset instead:
 *
 *   t:file f:<from> [d:<to>] ts:<ts> file:<sha>.<ext> size:<total> off:<n> b:<base64(raw[n:n+len])>
 *
 * `off:` is the byte offset the chunk begins at (the same field `cmd:file`
 * resume already uses), `b:` is base64url of the raw chunk, `size:` is the whole
 * length repeated on every packet. Integrity is the whole-file `file:` hash and
 * nothing else (§7.7.4's rule at this size): a wrong or forged chunk simply
 * makes the assembled sha not match, and the file is discarded. There is no
 * per-chunk signature — signing hundreds of tiny packets would cost more CPU
 * than the transfer — and a missing chunk is re-requested with `cmd:file off:`
 * exactly as a dead bulk transfer resumes.
 *
 * This is for SMALL binaries only. [maxBytes] bounds both what a sender will
 * packetise and what a receiver will buffer, so a stranger cannot fill memory
 * by announcing a huge `size:` and never completing it.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../../util/media_ref.dart';
import 'xprs_files.dart';
import 'xprs_packet.dart';
import 'xprs_vocab.dart';

/// The largest file this lane will carry, either way. 32 kB is ~360 packets —
/// a real meme, and a firm ceiling so the lane is never mistaken for the bulk
/// one. Anything larger is §7.7's business.
const int kInlineMaxBytes = 32 * 1024;

String _hex(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

/// Split [bytes] into `t:file` packets that carry the raw content by offset
/// (§7.7.6). Returns the wires in order, or empty if the file is too large for
/// this lane. The whole-file sha is computed once here; every packet repeats
/// the `file:` ref and `size:`, so any packet identifies the transfer.
List<String> xprsInlineSplit(
  Uint8List bytes, {
  required String from,
  String? to,
  required String ext,
  int? nowSec,
}) {
  if (bytes.isEmpty || bytes.length > kInlineMaxBytes) return const [];
  final sha = _hex(crypto.sha256.convert(bytes).bytes);
  final ref = '${MediaRef.hexToB64u(sha)}.$ext';
  final ts = xprsNowTs(nowSec == null ? null : nowSec * 1000);
  final dest = (to == null || to.trim().isEmpty) ? '' : ' d:${to.trim()}';
  // Fixed overhead per packet, then the biggest `b:` that still fits 250 bytes.
  // Computed against the largest offset so every packet uses one chunk size.
  final head = 't:file f:$from$dest ts:$ts file:$ref size:${bytes.length} '
      'off:${bytes.length} b:';
  // base64url of N raw bytes is 4*ceil(N/3) chars; invert to the raw bytes that
  // fit the remaining budget, rounded down to a multiple of 3 so no packet ends
  // on base64 padding.
  final budget = XprsPacket.maxBytes - head.length;
  var raw = (budget ~/ 4) * 3;
  if (raw < 3) return const []; // ext/callsigns too long to carry anything
  final wires = <String>[];
  for (var off = 0; off < bytes.length; off += raw) {
    final end = (off + raw < bytes.length) ? off + raw : bytes.length;
    final chunk = base64Url.encode(bytes.sublist(off, end)).replaceAll('=', '');
    wires.add('t:file f:$from$dest ts:$ts file:$ref '
        'size:${bytes.length} off:$off b:$chunk');
  }
  return wires;
}

/// A 7.7.6 chunk: a `t:file` carrying bytes by offset. Transient by nature —
/// three hundred of them per meme are not history, so the receive door feeds
/// them to the assembler and files none of them.
bool xprsIsInlineChunk(XprsPacket p) =>
    p.type == 'file' && p.has('b') && p.has('off');

/// The chunk grid a bitfield indexes (XPRS.md 7.7.6): every chunk but the last
/// has the same length, so chunk k begins at k times that length and bit k of
/// the map (section 8.1's form: least significant bit first, base64url) says
/// whether it is held. [chunkLen] is what [xprsInlineSplit] computed, or what a
/// receiver read off any full-length chunk it got.
int xprsInlineChunkCount(int size, int chunkLen) =>
    chunkLen <= 0 ? 0 : (size + chunkLen - 1) ~/ chunkLen;

/// Encode which chunks are held, LSB first, base64url without padding.
String xprsInlineHaveEncode(Iterable<int> heldOffsets, int size, int chunkLen) {
  final n = xprsInlineChunkCount(size, chunkLen);
  final bits = Uint8List((n + 7) >> 3);
  for (final off in heldOffsets) {
    if (off % chunkLen != 0) continue;
    final k = off ~/ chunkLen;
    if (k >= n) continue;
    bits[k >> 3] |= 1 << (k & 7);
  }
  return base64Url.encode(bits).replaceAll('=', '');
}

/// Decode a `have:` map to the set of chunk indexes it marks held; null when
/// it is not a map (`full`, a fraction, or junk).
Set<int>? xprsInlineHaveDecode(String have, int chunkCount) {
  if (have.isEmpty || have == 'full' || have.contains('/')) return null;
  Uint8List bits;
  try {
    bits = base64Url.decode(have.padRight((have.length + 3) & ~3, '='));
  } catch (_) {
    return null;
  }
  final held = <int>{};
  for (var k = 0; k < chunkCount; k++) {
    final byte = k >> 3;
    if (byte >= bits.length) break;
    if ((bits[byte] >> (k & 7)) & 1 == 1) held.add(k);
  }
  return held;
}

/// Buffers the chunks of incoming inline files until each is whole, then
/// verifies against the `file:` hash. Bounded in count and per-file size so it
/// cannot be grown without bound by a peer that never completes a transfer.
class XprsInlineAsm {
  XprsInlineAsm(
      {this.maxBytes = kInlineMaxBytes, this.maxFiles = 32, this.timers = true});
  static final XprsInlineAsm instance = XprsInlineAsm();
  final int maxBytes;
  final int maxFiles;
  static const Duration hold = Duration(minutes: 10);

  /// Whether a transfer arms its own one-shot idle timer. Off in tests, which
  /// drive [sweepStalled] with a clock of their own; the Android background
  /// case uses the same sweep off the native tick.
  final bool timers;

  /// How long a transfer may go without a chunk before the receiver says what
  /// it lacks, doubling per report; then it gives up and the buffer expires.
  /// Chunks arrive tens of milliseconds apart when they arrive at all, so ten
  /// seconds of silence is a lost packet, not a slow one.
  static const Duration idleGap = Duration(seconds: 10);
  static const int maxReports = 5;

  /// Called with the sender's callsign, the `file:` ref and the `have:` map
  /// (section 8.1's form) when a transfer has stalled — the core turns it into
  /// a signed `cmd:file ... have:` ask on the one send path. Counts in
  /// [reports].
  void Function(String from, String ref, String have)? onStalled;
  int reports = 0;

  /// Where a completed, verified inline file is handed for storage — set by the
  /// core (mesh_service) to `MediaArchive.putBytes`, so this module holds no
  /// store of its own (the archive is the core's, §3). Received count for logs.
  void Function(String ref, Uint8List bytes)? onFile;
  int received = 0;

  final Map<String, _Inbound> _files = {};

  int get pending => _files.length;

  /// Feed a heard packet from the receive door. A t:file chunk is buffered; a
  /// completed, verified file is handed to [onFile]. Anything else is ignored,
  /// so this is safe to call for every packet.
  int chunksHeard = 0;

  void feed(XprsPacket p, {DateTime? now}) {
    if (xprsIsInlineChunk(p)) chunksHeard++;
    final done = offer(p, now: now);
    if (done == null) return;
    received++;
    onFile?.call(done.$1, done.$2);
  }

  /// Offer one packet. Returns `(ref, bytes)` when [p] completed and VERIFIED a
  /// file, null while it is still partial or was not an inline-file chunk. A
  /// chunk whose assembled bytes fail the hash discards the whole buffer, so a
  /// poisoned chunk costs the sender a re-send, never a bad file.
  (String ref, Uint8List bytes)? offer(XprsPacket p, {DateTime? now}) {
    if (p.type != 'file') return null;
    final b = p['b'];
    final refv = p['file'];
    if (b == null || b.isEmpty || refv == null || refv.isEmpty) return null;
    final sha = xprsFileSha(refv);
    if (sha == null) return null;
    final size = int.tryParse(p['size'] ?? '');
    final off = int.tryParse(p['off'] ?? '');
    if (size == null || off == null || size <= 0 || off < 0) return null;
    if (size > maxBytes || off >= size) return null;

    final at = now ?? DateTime.now();
    _sweep(at);
    final from = (p['f'] ?? '').trim();
    final key = '$from|$sha';
    var inb = _files[key];
    if (inb == null) {
      if (_files.length >= maxFiles) {
        final oldest =
            _files.entries.reduce((a, b) => a.value.at.isBefore(b.value.at) ? a : b);
        _files.remove(oldest.key);
      }
      inb = _Inbound(size, xprsFileExt(refv), at);
      _files[key] = inb;
    }
    if (inb.size != size) return null; // size disagreement: not the same file
    inb.at = at;

    Uint8List chunk;
    try {
      chunk = base64Url.decode(b.padRight((b.length + 3) & ~3, '='));
    } catch (_) {
      return null;
    }
    if (off + chunk.length > size) return null; // a chunk past the end is junk
    inb.place(off, chunk);
    inb.from = from;
    inb.ref = refv;

    if (!inb.complete) {
      // Silence after this chunk is a lost one: say what we hold, once the
      // gap has passed. Re-armed on every chunk, so a live transfer never
      // reports.
      inb.nextReportAt = at.add(idleGap * (1 << inb.reports));
      if (timers) {
        inb.idle?.cancel();
        inb.idle = Timer(inb.nextReportAt.difference(at), () {
          _maybeReport(key, DateTime.now());
        });
      }
      return null;
    }
    inb.idle?.cancel();
    _files.remove(key);
    final whole = inb.bytes;
    if (_hex(crypto.sha256.convert(whole).bytes) != sha) {
      return null; // assembled but did not match: discard, sender re-sends
    }
    return ('file:${MediaRef.hexToB64u(sha)}.${inb.ext}', whole);
  }

  void _sweep(DateTime at) => _files.removeWhere((_, f) {
        final gone = at.difference(f.at) >= hold;
        if (gone) f.idle?.cancel();
        return gone;
      });

  /// The Android-background half of stall detection: a foreground timer does
  /// not fire while the app is backgrounded, so the native tick calls this.
  /// Safe to call as often as you like; a transfer reports at most once per
  /// gap, and never while chunks are still landing.
  void sweepStalled(DateTime now) {
    _sweep(now);
    for (final key in _files.keys.toList(growable: false)) {
      _maybeReport(key, now);
    }
  }

  void _maybeReport(String key, DateTime now) {
    final inb = _files[key];
    if (inb == null || inb.complete) return;
    if (now.isBefore(inb.nextReportAt)) return;
    if (inb.reports >= maxReports) return; // it will expire with [hold]
    final have = inb.haveEncoded();
    inb.reports++;
    inb.nextReportAt = now.add(idleGap * (1 << inb.reports));
    if (timers) {
      inb.idle?.cancel();
      inb.idle = Timer(inb.nextReportAt.difference(now), () {
        _maybeReport(key, DateTime.now());
      });
    }
    if (have == null) return; // no full chunk yet: the grid is unknown
    reports++;
    onStalled?.call(inb.from, inb.ref, have);
  }

  /// What is still missing of every transfer in flight: (from, ref, held
  /// chunks, total chunks). Diagnostics.
  List<(String from, String ref, int held, int total)> get inFlight => [
        for (final f in _files.values)
          (f.from, f.ref, f.spans.length,
              xprsInlineChunkCount(f.size, f.chunkLen)),
      ];
}

class _Inbound {
  _Inbound(this.size, this.ext, this.at)
      : _buf = Uint8List(size),
        nextReportAt = at;
  final int size;
  final String ext;
  DateTime at;
  final Uint8List _buf;
  final Set<int> _spans = {}; // start offsets seen, to count filled bytes
  int _filled = 0;

  /// The grid, learned from the first full-length chunk (7.7.6: every chunk
  /// but the last has the same length). Zero until one is seen.
  int chunkLen = 0;
  String from = '';
  String ref = '';
  int reports = 0;
  DateTime nextReportAt;
  Timer? idle;

  Set<int> get spans => _spans;

  void place(int off, Uint8List chunk) {
    if (_spans.contains(off)) return; // a repeated chunk is ignored
    _spans.add(off);
    _buf.setRange(off, off + chunk.length, chunk);
    _filled += chunk.length;
    if (chunkLen == 0 && off + chunk.length < size) chunkLen = chunk.length;
    // A file that fits one chunk: that chunk is the grid.
    if (chunkLen == 0 && off == 0 && chunk.length == size) chunkLen = size;
  }

  /// Section 8.1's map of what is held, or null while the grid is unknown.
  String? haveEncoded() =>
      chunkLen == 0 ? null : xprsInlineHaveEncode(_spans, size, chunkLen);

  bool get complete => _filled >= size;
  Uint8List get bytes => _buf;
}
