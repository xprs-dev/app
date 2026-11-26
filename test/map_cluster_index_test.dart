// The map's groups per zoom level (lib/wapp/geoui/map_cluster_index.dart):
// the same group at a zoom however the map is panned, a group's children
// one level closer, archivers never in a group with the rest, and the zoom
// at which a group comes apart (none for markers on one point).
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/map_cluster_index.dart';

(double, double) merc(double lat, double lon) {
  final r = pi / 180 * lat;
  return ((lon + 180) / 360, (1 - log(tan(r) + 1 / cos(r)) / pi) / 2);
}

void main() {
  MarkerClusterIndex build(List<(double, double)?> xy, {List<int>? group}) =>
      MarkerClusterIndex.build(xy, minZoom: 2, maxZoom: 18, group: group);

  test('every level holds every marker exactly once, and each node is its children', () {
    final rnd = Random(7);
    final xy = [for (var i = 0; i < 1500; i++) merc(38 + rnd.nextDouble() * 4, -9 + rnd.nextDouble() * 4)];
    final cx = build(xy);
    for (var z = 2; z <= 19; z++) {
      final seen = <int>{};
      for (final n in cx.at(z)) {
        for (final p in n.points) {
          expect(seen.add(p), isTrue, reason: 'marker $p twice at zoom $z');
        }
      }
      expect(seen.length, 1500, reason: 'zoom $z');
      if (z < 19) {
        final below = cx.at(z + 1);
        for (final n in cx.at(z)) {
          final kids = [for (final c in n.children) ...below[c].points]..sort();
          expect(kids, [...n.points]..sort());
        }
      }
    }
    expect(cx.at(2).length, lessThan(5), reason: 'a region at zoom 2 is a bubble or so');
    expect(cx.at(19).length, 1500);
  });

  test('a node and its ancestor agree from any level to any level above', () {
    final xy = [for (var i = 0; i < 200; i++) merc(49 + (i % 20) * 0.01, 8 + (i ~/ 20) * 0.01)];
    final cx = build(xy);
    for (var i = 0; i < cx.at(16).length; i++) {
      final a = cx.ancestor(16, i, 9);
      expect(cx.at(9)[a].points.toSet().containsAll(cx.at(16)[i].points), isTrue);
    }
  });

  test('archivers are never grouped with the rest', () {
    final xy = [merc(49.5, 8.5), merc(49.5, 8.5), merc(49.5, 8.5)];
    final cx = build(xy, group: [1, 0, 0]);
    for (var z = 2; z <= 18; z++) {
      final nodes = cx.at(z);
      expect(nodes.length, 2, reason: 'the archiver, and the two others');
      expect(nodes.firstWhere((n) => n.group == 1).count, 1);
    }
  });

  test('a group comes apart at its expansion zoom; markers on one point never do', () {
    final cx = build([merc(49.6, 8.7), merc(49.62, 8.74), merc(10, 10), merc(10, 10)]);
    final top = cx.at(5);
    final near = top.indexWhere((n) => n.count == 2 && n.points.contains(0));
    final ez = cx.expansionZoom(5, near)!;
    expect(cx.at(ez - 1).where((n) => n.points.contains(0)).single.count, 2);
    expect(cx.at(ez).where((n) => n.points.contains(0)).single.count, 1);
    final same = top.indexWhere((n) => n.points.contains(2));
    expect(cx.expansionZoom(5, same), isNull, reason: 'one point: fanned out, not zoomed');
  });

  test('a fan: 8 on a circle, more on a spiral, never two feet on each other', () {
    for (final n in [2, 5, 8, 9, 30]) {
      final f = spiderOffsets(n);
      expect(f.length, n);
      for (var i = 0; i < n; i++) {
        for (var j = i + 1; j < n; j++) {
          final d = sqrt(pow(f[i].$1 - f[j].$1, 2) + pow(f[i].$2 - f[j].$2, 2));
          expect(d, greaterThan(24), reason: '$n: feet $i and $j');
        }
      }
    }
  });
}
