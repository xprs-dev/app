/*
 * media_preview — a picture small enough to cross a public hub.
 *
 * The packet lane carries a file as ordinary 250-byte packets and tops out in
 * the low tens of kilobytes (XPRS.md §7.7.6). It is also the ONLY lane that
 * crosses a shared internet transport, which forwards directed packets and
 * drops a binary link (§12.12.1). A phone photograph is two to five megabytes.
 * So a photograph shared with somebody on another network arrives, today, not
 * at all.
 *
 * The answer is the one every messenger reached: send a small version now and
 * fetch the full one on demand. Here the small version is an ordinary file with
 * its own hash — the message carries it as its `file:`, and a companion
 * `t:file r:<message id>` names the original (§7.7.1 describes, §5 `r:`
 * refers). Nothing new goes on the wire: a preview is a file like any other,
 * fetched, verified, cached and served by the machinery that already exists.
 *
 * Why `package:image` and not `dart:ui`: the engine's codec is hardware-fast
 * but it only encodes PNG (a 512-pixel photo is 200-400 kB of it, which is not
 * a preview) and it cannot run outside the UI isolate. `image` is pure Dart —
 * a few hundred milliseconds for a 12 MP JPEG — so it runs on a worker
 * (docs/performance.md §8.1) and the UI never waits for it.
 */
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import '../../util/media_archive.dart';
import '../../util/media_ref.dart';
import '../background_service.dart';
import '../log_service.dart';
import '../xprs/xprs_inline_file.dart';

/// The most a preview may weigh. Comfortably inside the packet lane's cap so
/// the chunks, the message and its re-sends all fit the same budget.
const int kPreviewMaxBytes = 24 * 1024;

/// Longest side of a preview, and the smaller sides tried when quality alone
/// will not bring it under the cap. A noisy photograph is the worst case for
/// JPEG and the one that decides these numbers: the ladder keeps stepping down
/// until something fits, because a small preview is worth more than none.
const int kPreviewSide = 512;
const List<int> kPreviewSides = [512, 384, 256, 192];
const List<int> kPreviewQualities = [60, 45, 30, 20];

/// The largest original worth decoding for a preview. Above this the decode
/// costs more than the courtesy is worth, and the receiver taps instead.
const int kPreviewSourceMax = 20 * 1024 * 1024;

class MediaPreviews {
  MediaPreviews._();
  static final MediaPreviews instance = MediaPreviews._();

  /// The store. Injected by the core, like the rest of the media wiring.
  MediaArchive? Function()? archive;

  /// preview sha → original sha, and the reverse, for the session. The durable
  /// record is the `t:file r:` companion on the wire and the reference index
  /// that reads it; this is only so a send that happens seconds after an
  /// attach finds the preview it just made.
  final Map<String, String> _originalOf = {};
  final Map<String, String> _previewOf = {};

  int made = 0;
  int skipped = 0;

  /// The preview for [originalSha], if one was made this session.
  String? previewOf(String originalSha) => _previewOf[originalSha];

  /// The original a preview stands for, if it was made here.
  String? originalOf(String previewSha) => _originalOf[previewSha];

  /// Make a preview of [token] if it is a picture too big for the packet lane,
  /// and archive it. Returns the preview's `file:` token, or null when none is
  /// wanted (small enough already, not an image, too large to decode, or a
  /// format this build cannot read — HEIC has no pure-Dart decoder).
  ///
  /// Safe to call and forget: it is idempotent per hash and never throws.
  Future<String?> ensureFor(String token) async {
    final a = archive?.call();
    final ref = MediaRef.parse(token);
    if (a == null || ref == null) return null;
    final existing = _previewOf[ref.sha256];
    if (existing != null) return 'file:$existing.jpg';
    if (ref.kind != MediaKind.image) return null;
    final meta = a.getMeta(ref.sha256);
    if (meta == null) return null;
    if (meta.size <= kInlineMaxBytes) return null; // it already crosses a hub
    if (meta.size > kPreviewSourceMax) {
      skipped++;
      return null;
    }
    final bytes = a.get(ref.sha256);
    if (bytes == null) return null;

    Uint8List? small;
    try {
      small = await BackgroundService.runOffThread(() async => shrink(bytes));
    } catch (e) {
      LogService.instance.add('media: preview of ${ref.sha256Hex} failed ($e)');
      return null;
    }
    if (small == null) {
      skipped++;
      return null;
    }
    final ptoken = a.putBytes(small, 'jpg',
        name: meta.name == null ? null : 'preview-${meta.name}');
    final pref = MediaRef.parse(ptoken);
    if (pref == null) return null;
    _previewOf[ref.sha256] = pref.sha256;
    _originalOf[pref.sha256] = ref.sha256;
    made++;
    LogService.instance.add('media: preview ${small.length} B for '
        '${meta.size} B picture');
    return ptoken;
  }

  /// Decode, downscale and JPEG-encode until the result fits
  /// [kPreviewMaxBytes]. Pure and static so it runs on a worker isolate — no
  /// archive, no logging, nothing but bytes in and bytes out. Null when the
  /// format cannot be decoded here, or nothing small enough comes out.
  static Uint8List? shrink(Uint8List source) {
    if (source.isEmpty) return null;
    // The input is whatever somebody attached. A decoder handed a truncated
    // file, an empty one, or a format it does not know does not always answer
    // null — it throws — and a preview is a courtesy, never a reason to fail
    // a send.
    img.Image? decoded;
    try {
      decoded = img.decodeImage(source);
    } catch (_) {
      return null;
    }
    if (decoded == null) return null;
    final upright = img.bakeOrientation(decoded);
    for (final side in kPreviewSides) {
      final scaled = (upright.width >= upright.height)
          ? img.copyResize(upright, width: side)
          : img.copyResize(upright, height: side);
      for (final q in kPreviewQualities) {
        try {
          final out = img.encodeJpg(scaled, quality: q);
          if (out.length <= kPreviewMaxBytes) return out;
        } catch (_) {
          return null;
        }
      }
    }
    return null;
  }
}
