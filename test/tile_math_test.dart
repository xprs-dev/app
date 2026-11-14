// Which tiles cover an area: what ui.map.prefetch saves for off-grid use.
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/tile_math.dart';

void main() {
  test('tile coordinates follow the slippy-map convention', () {
    expect(tileX(-180, 0), 0);
    expect(tileX(0, 1), 1);
    expect(tileY(0, 1), 1);
    // Lisbon at zoom 12: (−9.1393+180)/360·4096 = 1944.0
    expect(tileX(-9.1393, 12), 1944);
    expect(tileY(38.7223, 12), 1569);
  });

  test('an area is covered coarse first, and never past the cap', () {
    final t = tilesForBox(38.70, -9.20, 38.75, -9.10, 10, 13);
    expect(t.first.z, 10);
    expect(t.last.z, 13);
    expect(t.where((x) => x.z == 10).length, lessThanOrEqualTo(2));
    expect(t.length, lessThan(40));
    final capped = tilesForBox(30, -20, 50, 10, 4, 12, cap: 100);
    expect(capped, hasLength(100));
    expect(capped.first.z, 4, reason: 'the overview survives a cap');
  });

  test('the area on a screen contains its centre and grows as the zoom drops', () {
    final (s, w, n, e) = viewBox(38.7223, -9.1393, 14, 1280, 800);
    expect(s < 38.7223 && 38.7223 < n, isTrue);
    expect(w < -9.1393 && -9.1393 < e, isTrue);
    final (s2, w2, n2, e2) = viewBox(38.7223, -9.1393, 13, 1280, 800);
    expect(e2 - w2, closeTo(2 * (e - w), 1e-9));
    expect(n2 - s2 > n - s, isTrue);
  });

  test('a template is filled per tile', () {
    expect(tileUrl('https://t/{z}/{x}/{y}.png', (z: 3, x: 4, y: 5)),
        'https://t/3/4/5.png');
  });

  test('a pinch keeps the point between the fingers where it was', () {
    const MapView v = (zoom: 12, x: 1000.0, y: 2000.0, scale: 1.0);
    final (nx, ny) = viewPoint(v, 150, 300);
    // Spread the fingers to 1.6x: half-way-ish to 13, still under them.
    final p = viewAt(nx, ny, 150, 300, viewZoom(v) + 0.678, 2, 18);
    expect(p.zoom, 13);
    expect(viewZoom(p), closeTo(12.678, 1e-9));
    final (mx, my) = viewPoint(p, 150, 300);
    expect(mx, closeTo(nx, 1e-12));
    expect(my, closeTo(ny, 1e-12));
    // The fingers move while pinching: the same point follows them.
    final q = viewAt(nx, ny, 190, 260, 12.3, 2, 18);
    expect(q.zoom, 12);
    final (qx, qy) = viewPoint(q, 190, 260);
    expect(qx, closeTo(nx, 1e-12));
    expect(qy, closeTo(ny, 1e-12));
  });

  test('a whole zoom draws tiles at their own size, and the limits hold', () {
    final v = viewAt(0.5, 0.5, 200, 200, 14, 2, 18);
    expect(v.scale, 1.0);
    expect(viewAt(0.5, 0.5, 0, 0, 25, 2, 18).zoom, 18);
    expect(viewAt(0.5, 0.5, 0, 0, -3, 2, 18).zoom, 2);
    expect(viewZoom(viewAt(0.5, 0.5, 0, 0, 25, 2, 18)), 18);
  });
}
