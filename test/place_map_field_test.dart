import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/widgets/place_map_field.dart';

void main() {
  group('PlaceMapField.parse', () {
    test('a map with numbers or numeric text', () {
      final a = PlaceMapField.parse({'lat': 38.7071, 'lon': -9.1393, 'label': 'X3STN1'})!;
      expect(a.lat, 38.7071);
      expect(a.lon, -9.1393);
      expect(a.label, 'X3STN1');
      final b = PlaceMapField.parse({'lat': '38.7', 'lon': '-9.1', 'zoom': 12})!;
      expect(b.lat, 38.7);
      expect(b.zoom, 12);
    });
    test('"lat,lon" text', () {
      final p = PlaceMapField.parse('38.7071, -9.1393')!;
      expect(p.lat, 38.7071);
      expect(p.lon, -9.1393);
    });
    test('nothing that is not a place', () {
      expect(PlaceMapField.parse(''), isNull);
      expect(PlaceMapField.parse(null), isNull);
      expect(PlaceMapField.parse({'lat': 91, 'lon': 0}), isNull);
      expect(PlaceMapField.parse({'lat': 0, 'lon': 0}), isNull);
      expect(PlaceMapField.parse('abc,def'), isNull);
    });
  });

  test('the tiles cover the view, the place in its middle', () {
    final c = PlaceMapField.worldPx(38.7071, -9.1393, 15);
    final t = PlaceMapField.tilesFor(c, 15, 400, 180);
    // Every tile is 256 px; together they reach every edge of the view.
    final left = t.map((e) => e.at.dx).reduce((a, b) => a < b ? a : b);
    final top = t.map((e) => e.at.dy).reduce((a, b) => a < b ? a : b);
    final right = t.map((e) => e.at.dx + 256).reduce((a, b) => a > b ? a : b);
    final bottom = t.map((e) => e.at.dy + 256).reduce((a, b) => a > b ? a : b);
    expect(left <= 0 && top <= 0 && right >= 400 && bottom >= 180, isTrue);
    expect(t.length, lessThanOrEqualTo(6));
    // The tile under the middle of the view holds the place.
    final mid = t.firstWhere((e) =>
        e.at.dx <= 200 && e.at.dx + 256 > 200 && e.at.dy <= 90 && e.at.dy + 256 > 90);
    expect(mid.tile.x, (c.dx / 256).floor());
    expect(mid.tile.y, (c.dy / 256).floor());
  });

  test('columns wrap round the antimeridian', () {
    final c = PlaceMapField.worldPx(0, 179.99, 2);
    final t = PlaceMapField.tilesFor(c, 2, 600, 100);
    expect(t.every((e) => e.tile.x >= 0 && e.tile.x < 4), isTrue);
  });

  testWidgets('draws its label and opens the full map on a tap', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: PlaceMapField(lat: 38.7071, lon: -9.1393, label: 'X3STN1'),
      ),
    ));
    expect(find.text('X3STN1'), findsOneWidget);
    expect(find.byIcon(Icons.location_on), findsOneWidget);
    await tester.tap(find.byType(PlaceMapField));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(AppBar), findsOneWidget);
  });
}
