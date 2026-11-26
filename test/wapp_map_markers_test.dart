// The wapp map with a region's stations on it: a crowd is grouped into
// count bubbles in one pass (no marker against every other), stations off
// screen cost nothing, and a marker's popup offers the wapp's actions.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/widgets/slippy_map.dart';

// A pin is keyed pin_<id> whether or not its label is shown.
int pins() => find
    .byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('pin_'))
    .evaluate()
    .length;

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  Future<void> pump(WidgetTester t, List<Map<String, dynamic>> markers,
      {void Function(String)? onTap, void Function(String, String)? onAction}) async {
    // The test map opens on Lisbon (38.7223, -9.1393) at zoom 10.
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
    final singles = pins();
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

  // At zoom 10 a degree of longitude is 256 * 1024 / 360 px.
  const k = 256 * 1024 / 360;
  const lat0 = 38.7223, lon0 = -9.1393;

  testWidgets('two pins either side of a grid line are one bubble, not two on top of each other', (t) async {
    // A pair 10 px apart, moved 3 px at a time across 70 px: it crosses a
    // 50 px square's edge on the way, and is never drawn as two pins.
    for (var d = 0.0; d < 70; d += 3) {
      await pump(t, [
        {'id': 'pl:A', 'lat': lat0, 'lon': lon0 + d / k, 'label': 'AAAAAA'},
        {'id': 'pl:B', 'lat': lat0, 'lon': lon0 + (d + 10) / k, 'label': 'BBBBBB'},
      ]);
      expect(pins(), 0, reason: 'at +$d px the two overlapping pins were both drawn');
      expect(find.text('2'), findsOneWidget);
    }
  });

  testWidgets('a grid of pins is not chained into one bubble', (t) async {
    await pump(t, [
      for (var i = 0; i < 6; i++)
        for (var j = 0; j < 6; j++)
          {'id': 'pl:G$i$j', 'lat': lat0 + j * 45 / k, 'lon': lon0 + i * 45 / k, 'label': 'G$i$j'},
    ]);
    final texts = find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? '');
    final counts = texts.map(int.tryParse).whereType<int>().toList();
    expect(counts.fold<int>(0, (a, b) => a + b) + pins(), 36);
    expect(counts.every((n) => n <= 9), isTrue, reason: 'no bubble swallows the grid: $counts');
  });

  testWidgets('a label that would cover another is left off, its pin stays and still opens', (t) async {
    final tapped = <String>[];
    await pump(t, [
      {'id': 'pl:LEFT', 'lat': lat0, 'lon': lon0, 'label': 'LEFTSTATION'},
      // 60 px to the right: apart as pins, not as labels.
      {'id': 'pl:RIGHT', 'lat': lat0, 'lon': lon0 + 60 / k, 'label': 'RIGHTSTATION'},
    ], onTap: tapped.add);
    expect(pins(), 2);
    final labels = find.text('LEFTSTATION').evaluate().length + find.text('RIGHTSTATION').evaluate().length;
    expect(labels, 1, reason: 'one label kept, the one that would cover it dropped');
    final hidden = find.text('LEFTSTATION').evaluate().isEmpty ? 'LEFT' : 'RIGHT';
    await t.tap(find.byKey(ValueKey('pin_pl:$hidden')));
    await settle(t);
    expect(tapped, ['pl:$hidden']);
    expect(find.text('${hidden}STATION'), findsWidgets, reason: 'the chosen pin names itself');
  });

  testWidgets('a bubble of pins on one point lists them; a row opens that pin', (t) async {
    final tapped = <String>[];
    await pump(t, [
      for (final c in ['X3ONE', 'X3TWO', 'X3SIX'])
        {'id': 'pl:$c', 'lat': lat0, 'lon': lon0, 'label': c, 'detail': '$c detail'},
    ], onTap: tapped.add);
    await t.tap(find.text('3'));
    await settle(t);
    expect(find.byKey(const ValueKey('cluster_list')), findsOneWidget);
    expect(find.text('3 here'), findsOneWidget);
    expect(find.text('X3TWO detail'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('cluster_row_pl:X3TWO')));
    await settle(t);
    expect(tapped, ['pl:X3TWO']);
    expect(find.byKey(const ValueKey('cluster_list')), findsNothing);
  });

  testWidgets('a bubble that zooming can split zooms in on it, far enough to split it', (t) async {
    await pump(t, [
      {'id': 'pl:P1', 'lat': lat0, 'lon': lon0 + 100 / k, 'label': 'P1'},
      {'id': 'pl:P2', 'lat': lat0, 'lon': lon0 + 106 / k, 'label': 'P2'},
    ]);
    await t.tap(find.text('2'));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('2'), findsNothing);
    expect(pins(), 2);
    // Centred on them.
    final p = t.getCenter(find.byKey(const ValueKey('pin_pl:P1')));
    expect(p.dx, inInclusiveRange(100, 300));
    expect(p.dy, inInclusiveRange(150, 550));
  });

  testWidgets('a long press on any bubble lists it', (t) async {
    await pump(t, [
      {'id': 'pl:L1', 'lat': lat0, 'lon': lon0, 'label': 'L1'},
      {'id': 'pl:L2', 'lat': lat0, 'lon': lon0 + 6 / k, 'label': 'L2'},
    ]);
    await t.longPress(find.text('2'));
    await settle(t);
    expect(find.text('2 here'), findsOneWidget);
  });
}
