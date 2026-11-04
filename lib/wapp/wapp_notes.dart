/*
 * A wapp's `social.note`: the wapp asks the host to publish one of OUR posts
 * as a signed NOSTR note, and the host hands it to the core
 * (RnsService.publishNote). One function for both hosts: the page and the
 * headless engine each carried their own copy.
 *
 * The preview thumbnail is the host's to make (dart:ui decoding, the wasm
 * video decoder), and only the page makes it, as before: a headless engine
 * publishes the text alone rather than decode images on a background tick.
 */
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../services/reticulum/rns_service.dart';
import '../util/media_ref.dart';
import 'geoui/widgets/media_view.dart' show sharedMediaArchive;
import 'native/wasm_video_player.dart' show WasmVideoThumbnailer;

/// Publish [text] as one of our NOSTR notes, in [topic] / replying to
/// [parent] when given. [withThumbnail] embeds a small preview of the first
/// picture or video it references (`tn:`), so peers can show it without
/// fetching the media.
Future<void> publishWappNote(String text,
    {String topic = '', String parent = '', bool withThumbnail = false}) async {
  if (text.isEmpty) return;
  final body = withThumbnail ? await _embedNoteThumbnail(text) : text;
  await RnsService.instance.publishNote(
    body,
    topic: topic.isEmpty ? null : topic,
    parent: parent.isEmpty ? null : parent,
  );
}

/// If [text] references a held image or video via a `file:` token, embed a
/// tiny PNG preview as a `tn:<base64url>` token so peers can render a
/// thumbnail for the post WITHOUT downloading the full file. Only the first
/// media that yields a preview, only when the encoded form stays small;
/// otherwise [text] is returned unchanged.
Future<String> _embedNoteThumbnail(String text) async {
  try {
    if (text.contains(' tn:')) return text; // already carries a preview
    final archive = sharedMediaArchive();
    if (archive == null) return text;
    for (final r in MediaRef.findAll(text)) {
      if (r.kind != MediaKind.image && r.kind != MediaKind.video) continue;
      // Reuse a cached poster if one exists, else generate + cache it.
      // Video posters come from the player wapp's wasm decoder (headless).
      var poster = archive.getScreenshot(r.sha256);
      if (poster == null) {
        final full = archive.get(r.sha256);
        if (full == null) continue; // not held — can't make a preview
        poster = r.kind == MediaKind.image
            ? await _thumbnailPng(full, 128)
            : await WasmVideoThumbnailer.generate(full, r.ext);
        if (poster == null) continue;
        archive.setScreenshot(r.sha256, poster);
      }
      // Wire copy: cached posters can be up to 360px — re-downscale so the
      // inline token stays small, dropping to 96px if 128px still busts the
      // cap (relay ingest allows 64 KB of content; stay well under).
      var wire = await _thumbnailPng(poster, 128) ?? poster;
      var b64 = base64Url.encode(wire);
      if (b64.length > 40000) {
        wire = await _thumbnailPng(poster, 96) ?? wire;
        b64 = base64Url.encode(wire);
        if (b64.length > 40000) continue; // too large to inline
      }
      return '$text tn:$b64';
    }
  } catch (_) {}
  return text;
}

/// Downscale [src] image bytes to a square-ish PNG at most [size] px wide, for
/// embedding in a profile note. Null on decode failure.
Future<Uint8List?> _thumbnailPng(Uint8List src, int size) async {
  try {
    final codec = await ui.instantiateImageCodec(src, targetWidth: size);
    final frame = await codec.getNextFrame();
    final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  } catch (_) {
    return null;
  }
}
