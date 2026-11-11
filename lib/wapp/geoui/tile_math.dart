// Which slippy-map tiles cover an area, for saving it before going off-grid.
// Pure arithmetic (Web Mercator, 256 px tiles): no Flutter, no I/O, so it is
// tested on its own and shared by every caller that prefetches tiles.

import 'dart:math' as math;

/// The tile column holding [lon] at [zoom].
int tileX(double lon, int zoom) {
  final n = 1 << zoom;
  return ((lon + 180.0) / 360.0 * n).floor().clamp(0, n - 1);
}

/// The tile row holding [lat] at [zoom] (Web Mercator; clamped to the
/// map's ±85.0511° edge).
int tileY(double lat, int zoom) {
  final n = 1 << zoom;
  final l = lat.clamp(-85.0511, 85.0511) * math.pi / 180.0;
  final y = (1 - math.log(math.tan(l) + 1 / math.cos(l)) / math.pi) / 2 * n;
  return y.floor().clamp(0, n - 1);
}

/// One tile.
typedef Tile = ({int z, int x, int y});

/// The tiles covering the box [south]..[north] x [west]..[east] at every
/// zoom from [minZoom] to [maxZoom], coarse first, at most [cap] of them.
/// A box crossing the antimeridian (west > east) is not split: callers pass
/// boxes around places, not around the planet.
List<Tile> tilesForBox(double south, double west, double north, double east,
    int minZoom, int maxZoom, {int cap = 2000}) {
  final out = <Tile>[];
  for (var z = minZoom; z <= maxZoom; z++) {
    final x0 = tileX(west, z), x1 = tileX(east, z);
    final y0 = tileY(north, z), y1 = tileY(south, z);
    for (var y = y0; y <= y1; y++) {
      for (var x = x0; x <= x1; x++) {
        if (out.length >= cap) return out;
        out.add((z: z, x: x, y: y));
      }
    }
  }
  return out;
}

/// The box a screen of [widthPx] x [heightPx] shows around [lat]/[lon] at
/// [zoom]: (south, west, north, east).
(double, double, double, double) viewBox(
    double lat, double lon, int zoom, double widthPx, double heightPx) {
  final scale = 256.0 * (1 << zoom);
  double lon2x(double lo) => (lo + 180.0) / 360.0 * scale;
  double lat2y(double la) {
    final l = la.clamp(-85.0511, 85.0511) * math.pi / 180.0;
    return (1 - math.log(math.tan(l) + 1 / math.cos(l)) / math.pi) / 2 * scale;
  }

  double x2lon(double x) => x / scale * 360.0 - 180.0;
  double y2lat(double y) {
    final n = math.pi - 2 * math.pi * y / scale;
    return 180.0 / math.pi * math.atan((math.exp(n) - math.exp(-n)) / 2);
  }

  final cx = lon2x(lon), cy = lat2y(lat);
  return (
    y2lat(cy + heightPx / 2),
    x2lon(cx - widthPx / 2),
    y2lat(cy - heightPx / 2),
    x2lon(cx + widthPx / 2),
  );
}

/// [template] with `{z}`, `{x}`, `{y}` filled in for [t].
String tileUrl(String template, Tile t) => template
    .replaceAll('{z}', '${t.z}')
    .replaceAll('{x}', '${t.x}')
    .replaceAll('{y}', '${t.y}');
