// The map's groups of markers, worked out once per zoom level (the method of
// Mapbox's supercluster, which Leaflet.markercluster's maps use too): at the
// deepest level every marker is its own node; each level up, a node takes in
// the nodes of the level below within [radius] screen pixels of it, and
// remembers them as its children. So a group is the same group whenever the
// map is at that zoom (a pan never regroups it), a group splits into exactly
// its children one zoom closer, and the map can slide markers between a node
// and its parent when the zoom changes.
//
// Pure Dart, no Flutter: positions are Web Mercator in [0, 1) (a whole world
// is 1 wide at every zoom), so a level's radius is radius / (256 * 2^z).
import 'dart:math';

/// One marker or group of markers at one zoom level.
class ClusterNode {
  /// Web Mercator position in [0, 1): the weighted middle of its markers.
  final double x, y;

  /// Indices into the markers the index was built from.
  final List<int> points;

  /// Its nodes one level deeper (indices into that level), and the node it
  /// belongs to one level up (-1 at the top).
  final List<int> children;
  int parent = -1;

  /// Markers of different groups (archivers and the rest) never share a node.
  final int group;

  ClusterNode(this.x, this.y, this.points, this.children, this.group);

  int get count => points.length;
}

class MarkerClusterIndex {
  final int minZoom, maxZoom;
  final double radius;

  /// [levels][z - minZoom] for z in minZoom..maxZoom+1; the last level is
  /// one node per marker.
  final List<List<ClusterNode>> levels;

  MarkerClusterIndex._(this.minZoom, this.maxZoom, this.radius, this.levels);

  /// [xy] is each marker's Mercator position (null: not on the map) and
  /// [group] its group.
  factory MarkerClusterIndex.build(
    List<(double, double)?> xy, {
    required int minZoom,
    required int maxZoom,
    double radius = 60,
    List<int>? group,
  }) {
    final leaves = <ClusterNode>[];
    for (var i = 0; i < xy.length; i++) {
      final p = xy[i];
      if (p == null) continue;
      leaves.add(ClusterNode(p.$1, p.$2, [i], const [], group?[i] ?? 0));
    }
    final levels = List<List<ClusterNode>>.filled(maxZoom - minZoom + 2, const []);
    levels[maxZoom - minZoom + 1] = leaves;
    for (var z = maxZoom; z >= minZoom; z--) {
      final below = levels[z - minZoom + 1];
      levels[z - minZoom] = _cluster(below, radius / (256 * pow(2, z)));
    }
    return MarkerClusterIndex._(minZoom, maxZoom, radius, levels);
  }

  /// One level up from [below]: each node in turn (the biggest first, so a
  /// crowd keeps its middle) takes in the free nodes within [r] of it.
  static List<ClusterNode> _cluster(List<ClusterNode> below, double r) {
    final grid = <int, List<int>>{};
    int key(int cx, int cy) => cx * 1000003 + cy;
    for (var i = 0; i < below.length; i++) {
      final n = below[i];
      grid.putIfAbsent(key((n.x / r).floor(), (n.y / r).floor()), () => []).add(i);
    }
    final order = List<int>.generate(below.length, (i) => i)
      ..sort((a, b) => below[b].count - below[a].count);
    final taken = List<bool>.filled(below.length, false);
    final out = <ClusterNode>[];
    final r2 = r * r;
    for (final i in order) {
      if (taken[i]) continue;
      taken[i] = true;
      final p = below[i];
      final kids = <int>[i];
      final cx = (p.x / r).floor(), cy = (p.y / r).floor();
      for (var dx = -1; dx <= 1; dx++) {
        for (var dy = -1; dy <= 1; dy++) {
          final cell = grid[key(cx + dx, cy + dy)];
          if (cell == null) continue;
          for (final j in cell) {
            if (taken[j]) continue;
            final q = below[j];
            if (q.group != p.group) continue;
            final ex = q.x - p.x, ey = q.y - p.y;
            if (ex * ex + ey * ey <= r2) {
              taken[j] = true;
              kids.add(j);
            }
          }
        }
      }
      double sx = 0, sy = 0;
      final pts = <int>[];
      for (final k in kids) {
        final c = below[k];
        sx += c.x * c.count;
        sy += c.y * c.count;
        pts.addAll(c.points);
      }
      final node = ClusterNode(sx / pts.length, sy / pts.length, pts, kids, p.group);
      final at = out.length;
      for (final k in kids) {
        below[k].parent = at;
      }
      out.add(node);
    }
    return out;
  }

  /// The level shown at zoom [z] (clamped to what was built).
  int levelFor(int z) => z.clamp(minZoom, maxZoom + 1);

  List<ClusterNode> at(int z) => levels[levelFor(z) - minZoom];

  /// The node at level [to] (above [from]) that node [i] of level [from]
  /// belongs to, as its index there.
  int ancestor(int from, int i, int to) {
    var z = levelFor(from), k = i;
    final top = levelFor(to);
    while (z > top) {
      k = levels[z - minZoom][k].parent;
      z--;
    }
    return k;
  }

  /// The zoom at which node [i] of level [z] comes apart (its markers in
  /// more than one node), or null when no zoom up to maxZoom parts them:
  /// markers on one point, or the map at its deepest already.
  int? expansionZoom(int z, int i) {
    var lz = levelFor(z), k = i;
    while (lz < maxZoom) {
      final n = levels[lz - minZoom][k];
      if (n.children.length > 1) return lz + 1;
      k = n.children.first;
      lz++;
    }
    return null;
  }
}

/// Where a fan of [n] markers sits around their point, in screen pixels
/// from it (Leaflet.markercluster's spiderfy): up to 8 on a circle, more
/// on a spiral, each [sep] pixels from the next so their labels fit.
List<(double, double)> spiderOffsets(int n, {double sep = 60}) {
  final out = <(double, double)>[];
  if (n <= 8) {
    final leg = max(sep * (2 + n) / (2 * pi), 56.0);
    final step = 2 * pi / n;
    for (var i = 0; i < n; i++) {
      final a = -pi / 2 + i * step; // the first one straight up
      out.add((leg * cos(a), leg * sin(a)));
    }
    return out;
  }
  var leg = 40.0, a = 0.0;
  for (var i = 0; i < n; i++) {
    a += sep * 0.8 / leg + i * 0.0005;
    out.add((leg * cos(a), leg * sin(a)));
    leg += 2 * pi * 6 / a;
  }
  return out;
}
