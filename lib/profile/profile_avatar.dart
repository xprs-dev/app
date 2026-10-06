/*
 * ProfileAvatar — circular avatar for an [IwiProfile].
 *
 * Renders the profile's uploaded image (read from `devices/<id>/<avatar>`)
 * when set, otherwise a coloured circle with the profile's initials. The
 * colour is the profile's chosen [IwiProfile.color] (see [kProfileColors]) or
 * a deterministic fallback derived from the callsign, so every identity gets a
 * stable, distinct colour even without customization.
 *
 * Rebuilds whenever ProfileService.revision changes (e.g. after the user
 * edits their avatar/colour in the profile editor).
 */

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../wapp/geoui/widgets/generated_avatar.dart';
import '../util/media_ref.dart';
import 'iwi_profile.dart';
import 'profile_service.dart';
import 'station_avatar.dart';

/// Map a [kProfileColors] name to a concrete colour.
Color profileColor(IwiProfile p) {
  switch (p.color) {
    case 'red':
      return const Color(0xFFE53935);
    case 'blue':
      return const Color(0xFF1E88E5);
    case 'green':
      return const Color(0xFF43A047);
    case 'yellow':
      return const Color(0xFFF9A825);
    case 'purple':
      return const Color(0xFF8E24AA);
    case 'orange':
      return const Color(0xFFFB8C00);
    case 'pink':
      return const Color(0xFFD81B60);
    case 'cyan':
      return const Color(0xFF00ACC1);
  }
  // Deterministic fallback from the callsign so it's stable + distinct.
  final h = p.callsign.codeUnits.fold<int>(0, (a, c) => (a * 31 + c) & 0x7fffffff);
  const palette = [
    Color(0xFFE53935), Color(0xFF1E88E5), Color(0xFF43A047),
    Color(0xFFF9A825), Color(0xFF8E24AA), Color(0xFFFB8C00),
    Color(0xFFD81B60), Color(0xFF00ACC1),
  ];
  return palette[h % palette.length];
}

/// Two-character initials for the circle fallback.
String profileInitials(IwiProfile p) {
  final src = (p.nickname.isNotEmpty ? p.nickname : p.wireCallsign).trim();
  if (src.isEmpty) return '?';
  final letters = src.replaceAll(RegExp(r'\s+'), '');
  return letters.substring(0, letters.length >= 2 ? 2 : 1).toUpperCase();
}

class ProfileAvatar extends StatelessWidget {
  final IwiProfile profile;
  final double size;

  const ProfileAvatar({super.key, required this.profile, this.size = 36});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: ProfileService.instance.revision,
      builder: (context, _, __) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    // No uploaded picture → the same deterministic identicon used across the
    // app, seeded by the callsign so the user's own icon matches everywhere.
    final fallback = GeneratedAvatar(seed: profile.callsign, size: size);

    if (profile.avatar.isEmpty) return fallback;
    final px = (size * (MediaQuery.maybeOf(context)?.devicePixelRatio ?? 2.0))
        .ceil();

    // The picture as other stations see it: a file in the media store.
    final ref = MediaRef.parse(profile.avatar);
    if (ref != null) {
      final bytes = stationPictureBytes(ref.sha256);
      if (bytes == null) return fallback;
      return _round(bytes, px, fallback);
    }

    // A profile from before that (XprsProfiles migrates it): the image in the
    // profile's own folder, decoded at the size it is drawn, not as picked.
    return FutureBuilder<Uint8List?>(
      future: ProfileService.instance
          .storageForProfile(profile.id)
          .readBytes(profile.avatar),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) return fallback;
        return _round(bytes, px, fallback);
      },
    );
  }

  Widget _round(Uint8List bytes, int px, Widget fallback) => ClipOval(
        child: Image.memory(
          bytes,
          width: size,
          height: size,
          cacheWidth: px,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => fallback,
        ),
      );
}
