import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xprs_core/src/services/xprs/xprs_shared_position.dart';

import '../services/i18n/core_i18n.dart';
import '../services/location_service.dart';
import '../services/preferences_service.dart';
import '../util/geohash.dart';

/// Settings → Location & privacy: the region this device says it serves
/// (docs/NOSTR.md). It sits beside location sharing because both say where the
/// station is; it used to live in Hardware, where it could not see the
/// "Location without GPS" set here and so never turned on for a station
/// without GPS.
class CoverageCard extends StatefulWidget {
  const CoverageCard({super.key});

  @override
  State<CoverageCard> createState() => _CoverageCardState();
}

class _CoverageCardState extends State<CoverageCard> {
  PreferencesService? get _prefs => PreferencesService.instanceSync;

  /// Where the device is: its fix, else the location typed for it without
  /// GPS, else null. Coverage is derived from it and never from a constant.
  Future<({double lat, double lon})?> _position() async {
    final loc = LocationService.instance;
    loc.ensureStarted();
    final lat = loc.latE7, lon = loc.lonE7;
    if (lat != null && lon != null) return (lat: lat / 1e7, lon: lon / 1e7);
    final fixed = xprsParseLatLon((_prefs?.positionFixed ?? '').trim());
    if (fixed != null) return fixed;
    return loc.currentPosition();
  }

  /// Re-encode the region at [precision] from the position. Always
  /// re-encoded, never padded: appending characters names a different place.
  /// With no position, a region already set is kept as it is.
  Future<void> _setCoverage(int precision) async {
    final p = _prefs;
    if (p == null) return;
    final at = await _position();
    if (!mounted) return;
    if (at == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr('hardware.no_fix'))));
      return;
    }
    setState(() =>
        p.nodeGeohash = geohashEncode(at.lat, at.lon, precision: precision));
  }

  /// The slider position while it is dragged; the region is re-encoded once,
  /// when it is let go.
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = _prefs;
    if (p == null) return const SizedBox.shrink();
    final g = p.nodeGeohash;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
      ),
      color: cs.surfaceContainerLow,
      child: Column(children: [
        SwitchListTile(
          secondary: const Icon(Icons.radar),
          title: Text(tr('hardware.coverage.title')),
          subtitle: Text(g.isEmpty
              ? tr('hardware.coverage.off')
              : tr('hardware.coverage.region',
                  {'geohash': g, 'precision': precisionName(g.length)})),
          value: g.isNotEmpty,
          onChanged: (on) {
            if (!on) {
              setState(() => p.nodeGeohash = '');
              return;
            }
            unawaited(_setCoverage(4));
          },
        ),
        if (g.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('hardware.coverage.precision'),
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
                Slider(
                  value: _dragging ?? g.length.clamp(2, 6).toDouble(),
                  min: 2,
                  max: 6,
                  divisions: 4,
                  label: precisionName(
                      (_dragging ?? g.length.toDouble()).round()),
                  onChanged: (v) => setState(() => _dragging = v),
                  onChangeEnd: (v) {
                    setState(() => _dragging = null);
                    unawaited(_setCoverage(v.round()));
                  },
                ),
                Text(tr('hardware.coverage.phone'),
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12)),
              ],
            ),
          ),
      ]),
    );
  }

  /// What a geohash of this length promises.
  static String precisionName(int len) => switch (len) {
        <= 2 => tr('hardware.precision.country'),
        3 => tr('hardware.precision.region'),
        4 => tr('hardware.precision.district'),
        5 => tr('hardware.precision.town'),
        _ => tr('hardware.precision.neighbourhood'),
      };
}
