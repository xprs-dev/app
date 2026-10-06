/*
 * station_avatar: a station's picture, wherever a screen shows a callsign.
 *
 * One path for every screen: our own picture from the profile, anybody else's
 * from what they announced (XPRS.md 6.3.2, kept by XprsProfiles), the bytes
 * from the media archive, decoded at the size they are drawn at and never
 * larger (docs/performance.md 8.9, 8.14). No picture is the identicon, the
 * same one the station has always had, so nothing jumps while bytes arrive.
 *
 * Showing a callsign is what tells the core a picture is wanted: a stranger's
 * is fetched only while a screen is showing them, on a budget the core keeps.
 */
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/media/media_fetch.dart';
import '../services/xprs/xprs_profiles.dart';
import '../util/media_ref.dart';
import '../wapp/geoui/widgets/generated_avatar.dart';
import 'profile_service.dart';

/// Decoded-once bytes per picture. A picture is about eight kilobytes and a
/// list shows a few dozen, so the archive is read once per picture rather than
/// once per row per frame.
final LinkedHashMap<String, Uint8List> _bytesBySha = LinkedHashMap();

/// The bytes of a held picture, read once (see [_bytesBySha]).
Uint8List? stationPictureBytes(String sha) => _bytesOf(sha);

Uint8List? _bytesOf(String sha) {
  final hit = _bytesBySha.remove(sha);
  if (hit != null) {
    _bytesBySha[sha] = hit;
    return hit;
  }
  final b = MediaFetch.instance.archive?.call()?.get(sha);
  if (b == null || b.isEmpty) return null;
  _bytesBySha[sha] = b;
  if (_bytesBySha.length > 128) _bytesBySha.remove(_bytesBySha.keys.first);
  return b;
}

String _base(String call) {
  final c = call.trim().toUpperCase();
  final dash = c.indexOf('-');
  return dash < 0 ? c : c.substring(0, dash);
}

/// Our own callsign, by either of its names (XPRS.md 6.4.1).
bool isOwnCallsign(String call) {
  final p = ProfileService.instance.activeProfile;
  if (p == null) return false;
  final c = _base(call);
  return c.isNotEmpty &&
      (c == _base(p.wireCallsign) || c == _base(p.callsign));
}

/// The picture of [call], as a reference, or null when it has none known.
MediaRef? stationPictureRef(String call) {
  if (isOwnCallsign(call)) {
    return MediaRef.parse(ProfileService.instance.activeProfile?.avatar ?? '');
  }
  return XprsProfiles.instance.pictureFor(call);
}

/// The picture of [call] decoded at [px] pixels, or null when it has none
/// here yet. Asks for a stranger's picture when [want] (a screen showing it).
ImageProvider? stationAvatarImage(String call, {int px = 128, bool want = true}) {
  final ref = stationPictureRef(call);
  if (ref == null) return null;
  final bytes = _bytesOf(ref.sha256);
  if (bytes == null) {
    if (want && !isOwnCallsign(call)) XprsProfiles.instance.wantPicture(call);
    return null;
  }
  return ResizeImage(MemoryImage(bytes),
      width: px, height: px, allowUpscaling: false);
}

/// A round picture for [callsign], or [fallback] (the identicon by default).
class StationAvatar extends StatelessWidget {
  final String callsign;
  final double size;
  final Widget? fallback;

  const StationAvatar(
      {super.key, required this.callsign, this.size = 40, this.fallback});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: XprsProfiles.instance.revision,
      builder: (context, _, _) => ValueListenableBuilder<int>(
        valueListenable: ProfileService.instance.revision,
        builder: (context, _, _) {
          final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0;
          final img =
              stationAvatarImage(callsign, px: (size * dpr).ceil());
          final fb = fallback ?? GeneratedAvatar(seed: callsign, size: size);
          if (img == null) return fb;
          return ClipOval(
            child: Image(
              image: img,
              width: size,
              height: size,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => fb,
            ),
          );
        },
      ),
    );
  }
}
