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

/// What a slippy map shows: whole tile [zoom], the world pixel ([x], [y], at
/// that zoom) at the view's top-left corner, and the [scale] the tiles are
/// drawn at. [scale] is 1 at rest and between about 0.7 and 1.4 while a pinch
/// sits between two zoom levels.
typedef MapView = ({int zoom, double x, double y, double scale});

/// The zoom [v] shows, with the pinch's fraction: zoom 12 drawn at 1.41 is
/// 12.5.
double viewZoom(MapView v) => v.zoom + math.log(v.scale) / math.ln2;

/// The point under screen position ([sx], [sy]) as a fraction of the whole
/// world (0..1 each way), which does not change with zoom.
(double, double) viewPoint(MapView v, double sx, double sy) {
  final world = 256.0 * math.pow(2, v.zoom);
  return ((v.x + sx / v.scale) / world, (v.y + sy / v.scale) / world);
}

/// The view at [zoom] (any fraction, clamped to [minZoom]..[maxZoom]) that
/// keeps the world point ([nx], [ny]) (from [viewPoint]) under screen
/// position ([fx], [fy]). A pinch, a double tap, the mouse wheel and a fling
/// are all this with different numbers: the point between the fingers stays
/// between the fingers.
MapView viewAt(double nx, double ny, double fx, double fy, double zoom,
    int minZoom, int maxZoom) {
  final zc = zoom.clamp(minZoom.toDouble(), maxZoom.toDouble());
  final z = zc.round();
  final s = math.pow(2, zc - z).toDouble();
  final world = 256.0 * math.pow(2, z);
  return (zoom: z, x: nx * world - fx / s, y: ny * world - fy / s, scale: s);
}
