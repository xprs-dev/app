// A GeoUI field (`$type:"place"`): one place on a small map. It is for a
// record that happened somewhere (a check-in, an event, a station's pin):
// a still map a few tiles wide, centred on the place, with a pin and its
// label. Tapping it opens the same place on the full interactive map
// (SlippyMap), where it can be panned and zoomed.
//
// Value (ui.field.set): {"lat","lon","label"?,"zoom"?} or "lat,lon".
// Attributes on the field: `zoom` (default 15), `height` (default 180),
// `tile-url`, `tile-style` (as on a map group, §14.0.1). No value, or one
// that is not a place, draws nothing.
//
// The tiles come from the same disk cache as every map (tile_cache.dart), so
// a place once seen shows off-grid, and are decoded by the image cache off the
// build. Nothing is computed per frame but a handful of tile offsets.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../tile_cache.dart';
import '../tile_math.dart' as tiles;
import 'slippy_map.dart';

const String kDefaultTileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';

class PlaceMapField extends StatelessWidget {
  const PlaceMapField({
    super.key,
    required this.lat,
    required this.lon,
    this.label = '',
    this.zoom = 15,
    this.height = 180,
    this.tileUrl = kDefaultTileUrl,
    this.tileStyle = '',
  });

  final double lat, lon;
  final String label;
  final int zoom;
  final double height;
  final String tileUrl, tileStyle;

  /// The place a field value names, or null: a map {lat, lon, label?,
  /// zoom?} (numbers or numeric strings), or text "lat,lon".
  static ({double lat, double lon, String label, int? zoom})? parse(Object? v) {
    double? num_(Object? x) =>
        x is num ? x.toDouble() : (x is String ? double.tryParse(x.trim()) : null);
    double? la, lo;
    var label = '';
    int? zoom;
    if (v is Map) {
      la = num_(v['lat']);
      lo = num_(v['lon']);
      label = v['label']?.toString() ?? '';
      zoom = num_(v['zoom'])?.round();
    } else if (v is String && v.contains(',')) {
      final p = v.split(',');
      la = num_(p[0]);
      lo = num_(p[1]);
    }
    if (la == null || lo == null) return null;
    if (la.isNaN || lo.isNaN || la.abs() > 90 || lo.abs() > 180) return null;
    if (la == 0 && lo == 0) return null; // "nowhere", not the Gulf of Guinea
    return (lat: la, lon: lo, label: label, zoom: zoom);
  }

  /// [lat]/[lon] in world pixels at [z] (Web Mercator, 256 px tiles).
  static Offset worldPx(double lat, double lon, int z) {
    final scale = 256.0 * (1 << z);
    final l = lat.clamp(-85.0511, 85.0511) * math.pi / 180.0;
    return Offset(
      (lon + 180.0) / 360.0 * scale,
      (1 - math.log(math.tan(l) + 1 / math.cos(l)) / math.pi) / 2 * scale,
    );
  }

  /// The tiles a [w] x [h] view centred on [c] (world px) needs at [z], each
  /// with where its top-left corner falls in the view. Columns wrap round the
  /// antimeridian; rows off the top or bottom of the world are left out.
  static List<({tiles.Tile tile, Offset at})> tilesFor(
      Offset c, int z, double w, double h) {
    final n = 1 << z;
    final left = c.dx - w / 2, top = c.dy - h / 2;
    final x0 = (left / 256).floor(), x1 = ((left + w) / 256).floor();
    final y0 = (top / 256).floor(), y1 = ((top + h) / 256).floor();
    final out = <({tiles.Tile tile, Offset at})>[];
    for (var y = y0; y <= y1; y++) {
      if (y < 0 || y >= n) continue;
      for (var x = x0; x <= x1; x++) {
        out.add((
          tile: (z: z, x: ((x % n) + n) % n, y: y),
          at: Offset(x * 256 - left, y * 256 - top),
        ));
      }
    }
    return out;
  }

  void _open(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => _PlacePage(
        lat: lat,
        lon: lon,
        label: label,
        zoom: zoom,
        tileUrl: tileUrl,
        tileStyle: tileStyle,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final z = zoom.clamp(1, 19);
    return Semantics(
      button: true,
      label: label.isEmpty ? 'Map' : 'Map: $label',
      child: GestureDetector(
        onTap: () => _open(context),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: height,
            child: LayoutBuilder(builder: (context, box) {
              final w = box.maxWidth, h = box.maxHeight;
              final c = worldPx(lat, lon, z);
              return Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  Positioned.fill(child: ColoredBox(color: cs.surfaceContainerHighest)),
                  for (final t in tilesFor(c, z, w, h))
                    Positioned(
                      left: t.at.dx,
                      top: t.at.dy,
                      width: 256,
                      height: 256,
                      child: Image(
                        image: tileImageProvider(tiles.tileUrl(tileUrl, t.tile),
                            style: tileStyle),
                        fit: BoxFit.fill,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
                    ),
                  // The pin's point sits on the place.
                  Positioned(
                    left: w / 2 - 18,
                    top: h / 2 - 36,
                    child: const Icon(Icons.location_on,
                        size: 36,
                        color: Color(0xFFE53935),
                        shadows: [Shadow(blurRadius: 4, color: Color(0x88000000))]),
                  ),
                  if (label.isNotEmpty)
                    Positioned(
                      left: 8,
                      top: 8,
                      child: _chip(label, const Color(0xE6FFFFFF), Colors.black87, 13),
                    ),
                  Positioned(
                    right: 8,
                    top: 8,
                    child: _chip('', const Color(0xE6FFFFFF), Colors.black87, 13,
                        icon: Icons.open_in_full),
                  ),
                  // The tiles' licence asks for this on every map that shows them.
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      color: const Color(0xB3FFFFFF),
                      child: const Text('© OpenStreetMap',
                          style: TextStyle(fontSize: 9, color: Colors.black87)),
                    ),
                  ),
                ],
              );
            }),
          ),
        ),
      ),
    );
  }

  static Widget _chip(String text, Color bg, Color fg, double size, {IconData? icon}) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: icon != null ? 5 : 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [BoxShadow(blurRadius: 3, color: Color(0x33000000))],
      ),
      child: icon != null
          ? Icon(icon, size: 16, color: fg)
          : Text(text,
              style: TextStyle(fontSize: size, color: fg, fontWeight: FontWeight.w600)),
    );
  }
}

/// The place on the full map: pan, zoom, one pin.
class _PlacePage extends StatelessWidget {
  const _PlacePage({
    required this.lat,
    required this.lon,
    required this.label,
    required this.zoom,
    required this.tileUrl,
    required this.tileStyle,
  });
  final double lat, lon;
  final String label;
  final int zoom;
  final String tileUrl, tileStyle;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(label.isEmpty ? 'Map' : label)),
      body: SlippyMap(
        lat: lat,
        lon: lon,
        zoom: zoom,
        minZoom: 2,
        maxZoom: 19,
        tileUrl: tileUrl,
        tileStyle: tileStyle,
        showSearch: false,
        embedChat: false,
        onViewportChanged: (_, _, _) {},
        markers: [
          {'id': 'place', 'lat': lat, 'lon': lon, 'label': label, 'color': '#E53935'},
        ],
      ),
    );
  }
}
