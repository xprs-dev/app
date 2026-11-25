// The wapp map with a region's stations on it: a crowd is grouped into
// count bubbles in one pass (no marker against every other), stations off
// screen cost nothing, and a marker's popup offers the wapp's actions.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/widgets/slippy_map.dart';

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  Future<void> pump(WidgetTester t, List<Map<String, dynamic>> markers,
      {void Function(String)? onTap, void Function(String, String)? onAction}) async {
    t.view.physicalSize = const Size(400, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: slippyMapForTest(
          onViewportChanged: (_, __, ___) {},
          markers: markers,
          onMarkerTap: onTap,
          onMarkerAction: onAction,
        ),
      ),
    ));
    await settle(t);
  }

  testWidgets('1500 stations in one town are a few bubbles, drawn fast', (t) async {
    final markers = [
      for (var i = 0; i < 1500; i++)
        {
          'id': 'pl:X3S$i',
          'lat': 38.62 + (i % 100) * 0.002,
          'lon': -9.15 + (i ~/ 100) * 0.002,
          'label': 'X3S$i',
        },
    ];
    final sw = Stopwatch()..start();
    await pump(t, markers);
    sw.stop();
    // Every station is counted in some bubble, none drawn twice.
    final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? '').toList();
    final counts = texts.map(int.tryParse).whereType<int>().fold<int>(0, (a, b) => a + b);
    final singles = texts.where((s) => s.startsWith('X3S')).length;
    expect(counts + singles, 1500);
    expect(singles, lessThan(40), reason: 'a crowd is grouped, not 1500 pins');
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });

  testWidgets('a bubble of thousands says 1.5k', (t) async {
    await pump(t, [
      for (var i = 0; i < 1500; i++)
        {'id': 'pl:X3K$i', 'lat': 38.7223, 'lon': -9.1393, 'label': 'X3K$i'},
    ]);
    expect(find.text('1.5k'), findsOneWidget);
  });

  testWidgets('stations far off screen are not placed', (t) async {
    await pump(t, [
      {'id': 'pl:HERE', 'lat': 38.7223, 'lon': -9.1393, 'label': 'HERE'},
      {'id': 'pl:FAR', 'lat': 60.0, 'lon': 20.0, 'label': 'FAR'},
    ]);
    expect(find.text('HERE'), findsOneWidget);
    expect(find.text('FAR'), findsNothing);
  });

  testWidgets("a marker's popup offers the wapp's actions", (t) async {
    final tapped = <String>[], acted = <String>[];
    await pump(t, [
      {
        'id': 'pl:X3ABC',
        'lat': 38.7223,
        'lon': -9.1393,
        'label': 'X3ABC',
        'detail': 'Hill · 5 min ago',
        'actions': [
          {'id': 'open', 'label': 'Open'},
          {'id': 'message', 'label': 'Message'},
        ],
      },
    ], onTap: tapped.add, onAction: (id, a) => acted.add('$id/$a'));
    await t.tap(find.text('X3ABC'));
    await settle(t);
    expect(tapped, ['pl:X3ABC']);
    expect(find.text('Message'), findsOneWidget);
    await t.tap(find.text('Message'));
    await settle(t);
    expect(acted, ['pl:X3ABC/message']);
    expect(find.text('Open'), findsNothing, reason: 'the popup closes');
  });
}
