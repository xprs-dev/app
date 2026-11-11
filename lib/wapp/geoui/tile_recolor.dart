// Recolouring of raster map tiles, for a map's `tile-style`.
//
// `dark` repaints an OpenStreetMap-carto tile in the palette of the Protomaps
// "dark" basemap flavour (protomaps.com; the theme bitchatexplorer.com uses):
// near-black land, blue-grey water, dark green parks, grey roads, light grey
// labels. OSM-carto paints each kind of place in a few fixed colours, so a
// pixel's hue tells what it was and its luminance places it in the new
// ramp. The neutral ramp is piecewise linear, so anti-aliased edges between
// land, roads, buildings and text stay smooth instead of fringing.
//
// Pure Dart on a plain RGBA buffer: it runs off the UI isolate and is tested
// without Flutter.

import 'dart:typed_data';

/// Whether [style] is a recolouring done on the tile's pixels (as opposed
/// to a colour-matrix filter or nothing).
bool isRecolorStyle(String style) => style == 'dark';

// The Protomaps "dark" flavour (@protomaps/basemaps, namedFlavor("dark")).
const _water = 0x31353f, _park = 0x1c2421, _sand = 0x212123;
const _major = 0x474747, _boundary = 0x5b6374;

// OSM luminance -> dark luminance: text -> light grey, buildings (~210) ->
// a shade darker than land, land (~239) -> earth #1f1f1f, roads and label
// halos (255) -> #3d3d3d.
const _ramp = <List<int>>[
  [0, 175], [110, 120], [185, 24], [212, 17], [236, 31], [244, 31], [255, 61],
];

final Uint8List _lum = () {
  final t = Uint8List(256);
  for (var l = 0; l < 256; l++) {
    var v = _ramp.last[1].toDouble();
    for (var i = 0; i + 1 < _ramp.length; i++) {
      final a = _ramp[i], b = _ramp[i + 1];
      if (l <= b[0]) {
        v = a[1] + (b[1] - a[1]) * (l - a[0]) / (b[0] - a[0]);
        break;
      }
    }
    t[l] = v.round();
  }
  return t;
}();

/// Repaints [rgba] (straight RGBA, 8 bits a channel) in place into the
/// Protomaps dark palette. Alpha is left as it is.
Uint8List recolorDark(Uint8List rgba) {
  for (var i = 0; i + 3 < rgba.length; i += 4) {
    final r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    final l = (299 * r + 587 * g + 114 * b) ~/ 1000;
    final grey = _lum[l];
    final mx = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final mn = r < g ? (r < b ? r : b) : (g < b ? g : b);
    final chroma = mx - mn;
    if (chroma < 14) {
      rgba[i] = rgba[i + 1] = rgba[i + 2] = grey;
      continue;
    }
    int target;
    if (b >= g - 8 && b > r + 15 && g > r) {
      // water; a label written on it keeps its light grey
      if (l < 150) {
        rgba[i] = rgba[i + 1] = rgba[i + 2] = grey;
        continue;
      }
      target = _water;
    } else if (g > r + 6 && g >= b) {
      target = _park; // parks, woods, grass
    } else if (r > b + 20 && l > 215 && chroma < 56 && r - g < 20) {
      target = _sand; // sand, beach, desert
    } else if (r > b + 20 && (g > b + 10 || r > g + 20)) {
      target = _major; // yellow, orange and pink roads
    } else {
      target = _boundary; // borders and other accents
    }
    // weak colour stays partly grey: the anti-aliased rim of a shape
    final t = chroma >= 44 ? 30 : chroma - 14; // out of 30
    rgba[i] = grey + (((target >> 16) - grey) * t) ~/ 30;
    rgba[i + 1] = grey + ((((target >> 8) & 0xff) - grey) * t) ~/ 30;
    rgba[i + 2] = grey + (((target & 0xff) - grey) * t) ~/ 30;
  }
  return rgba;
}
