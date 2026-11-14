// The wapp map's gestures: a two-finger pinch zooms around the fingers, one
// finger pans, a double tap zooms in, and a pin still takes a tap.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/widgets/slippy_map.dart';

// The map pulses a highlight forever, so it never "settles": pump past the
// longest ease (260 ms) instead.
Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  Future<List<(double, double, int)>> pump(WidgetTester t,
      {List<Map<String, dynamic>> markers = const [],
      void Function(String)? onTap}) async {
    final seen = <(double, double, int)>[];
    t.view.physicalSize = const Size(400, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: slippyMapForTest(
          onViewportChanged: (la, lo, z) => seen.add((la, lo, z)),
          markers: markers,
          onMarkerTap: onTap,
        ),
      ),
    ));
    await settle(t);
    return seen;
  }

  testWidgets('a pinch out zooms in and keeps the centre where it was',
      (t) async {
    final seen = await pump(t);
    final c = t.getCenter(find.byType(Scaffold));
    final a = await t.startGesture(c - const Offset(40, 0), pointer: 1);
    final b = await t.startGesture(c + const Offset(40, 0), pointer: 2);
    for (var i = 1; i <= 10; i++) {
      await a.moveTo(c - Offset(40.0 + i * 12, 0));
      await b.moveTo(c + Offset(40.0 + i * 12, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await settle(t);
    final (lat, lon, z) = seen.last;
    // Fingers 80 px apart to 320: four times, two zoom levels.
    expect(z, 12);
    expect(lat, closeTo(38.7223, 0.01));
    expect(lon, closeTo(-9.1393, 0.01));
  });

  testWidgets('a pinch in zooms out', (t) async {
    final seen = await pump(t);
    final c = t.getCenter(find.byType(Scaffold));
    final a = await t.startGesture(c - const Offset(160, 0), pointer: 1);
    final b = await t.startGesture(c + const Offset(160, 0), pointer: 2);
    for (var i = 1; i <= 10; i++) {
      await a.moveTo(c - Offset(160.0 - i * 12, 0));
      await b.moveTo(c + Offset(160.0 - i * 12, 0));
      await t.pump(const Duration(milliseconds: 16));
    }
    await a.up();
    await b.up();
    await settle(t);
    expect(seen.last.$3, 8);
  });

  testWidgets('one finger pans without changing the zoom', (t) async {
    final seen = await pump(t);
    final c = t.getCenter(find.byType(Scaffold));
    final g = await t.startGesture(c);
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(c + Offset(i * 10.0, 0));
      await t.pump(const Duration(milliseconds: 100));
    }
    await g.up();
    await settle(t);
    final (_, lon, z) = seen.last;
    expect(z, 10);
    expect(lon, lessThan(-9.2), reason: 'dragging right shows the west');
  });

  testWidgets('a double tap zooms in one step', (t) async {
    final seen = await pump(t);
    final c = t.getCenter(find.byType(Scaffold));
    await t.tapAt(c);
    await t.pump(const Duration(milliseconds: 60));
    await t.tapAt(c);
    await settle(t);
    expect(seen.last.$3, 11);
  });

  testWidgets('a pin takes a tap', (t) async {
    String? tapped;
    await pump(t,
        markers: [
          {'id': 'st:CT1ABC', 'lat': 38.7223, 'lon': -9.1393, 'label': 'CT1ABC'}
        ],
        onTap: (id) => tapped = id);
    await t.tap(find.text('CT1ABC'));
    await settle(t);
    expect(tapped, 'st:CT1ABC');
  });
}
