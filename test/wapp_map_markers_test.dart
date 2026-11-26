// The wapp map with a region's stations on it, as Leaflet.markercluster's
// map behaves on the xprs.dev portal: groups worked out per zoom level (a
// pan never regroups them), a tapped group zooms in to where it comes apart
// with its markers sliding out, stations on one point fan out around it on
// legs, archivers drawn apart and above the rest, and a marker's popup
// offering the wapp's actions.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/widgets/slippy_map.dart';

// A pin is keyed pin_<id>.
Finder pinsF() => find.byWidgetPredicate(
    (w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('pin_'));
int pins() => pinsF().evaluate().length;

List<int> bubbles() => find
    .byType(Text)
    .evaluate()
    .map((e) => (e.widget as Text).data ?? '')
    .map(int.tryParse)
    .whereType<int>()
    .toList();

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

// The test map opens on Lisbon at zoom 10: a degree of longitude is
// 256 * 1024 / 360 px.
const k = 256 * 1024 / 360;
const lat0 = 38.7223, lon0 = -9.1393;

void main() {
  Future<void> pump(WidgetTester t, List<Map<String, dynamic>> markers,
      {void Function(String)? onTap,
      void Function(String, String)? onAction,
      void Function(List<String>)? onHere,
      String? openId,
      int openSeq = 0,
      int zoom = 10}) async {
    t.view.physicalSize = const Size(400, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: slippyMapForTest(
          zoom: zoom,
          onViewportChanged: (_, __, ___) {},
          markers: markers,
          onMarkerTap: onTap,
          onMarkerAction: onAction,
          onMarkersHere: onHere,
          openId: openId,
          openSeq: openSeq,
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
    expect(bubbles().fold<int>(0, (a, b) => a + b) + pins(), 1500, reason: 'each counted once');
    expect(pins(), lessThan(40), reason: 'a crowd is grouped, not 1500 pins');
    expect(sw.elapsedMilliseconds, lessThan(5000));
  });

  testWidgets('a bubble of thousands says 1.5k', (t) async {
    await pump(t, [
      for (var i = 0; i < 1500; i++) {'id': 'pl:X3K$i', 'lat': lat0, 'lon': lon0, 'label': 'X3K$i'},
    ]);
    expect(find.text('1.5k'), findsOneWidget);
  });

  testWidgets('stations far off screen are not placed', (t) async {
    await pump(t, [
      {'id': 'pl:HERE', 'lat': lat0, 'lon': lon0, 'label': 'HERE'},
      {'id': 'pl:FAR', 'lat': 60.0, 'lon': 20.0, 'label': 'FAR'},
    ]);
    expect(find.text('HERE'), findsOneWidget);
    expect(find.text('FAR'), findsNothing);
  });

  testWidgets('every pin keeps its label', (t) async {
    await pump(t, [
      {'id': 'pl:LEFT', 'lat': lat0, 'lon': lon0, 'label': 'LEFTSTATION'},
      {'id': 'pl:RIGHT', 'lat': lat0, 'lon': lon0 + 70 / k, 'label': 'RIGHTSTATION'},
    ]);
    expect(find.text('LEFTSTATION'), findsOneWidget);
    expect(find.text('RIGHTSTATION'), findsOneWidget);
  });

  testWidgets("labels are whole at a phone's larger text", (t) async {
    t.view.physicalSize = const Size(400, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(400, 700), textScaler: TextScaler.linear(1.3)),
        child: Scaffold(
          body: slippyMapForTest(onViewportChanged: (_, __, ___) {}, markers: [
            {'id': 'pl:X1WATT', 'lat': lat0, 'lon': lon0, 'label': 'X1WATT'},
            {'id': 'pl:X3PTZM', 'lat': lat0, 'lon': lon0 + 90 / k, 'label': 'X3PTZM', 'kind': 'archive'},
          ]),
        ),
      ),
    ));
    await settle(t);
    for (final c in ['X1WATT', 'X3PTZM']) {
      final p = t.renderObject<RenderParagraph>(find.text(c));
      expect(p.didExceedMaxLines, isFalse, reason: '$c cut short');
    }
  });

  testWidgets("a marker's popup offers the wapp's actions", (t) async {
    final tapped = <String>[], acted = <String>[];
    await pump(t, [
      {
        'id': 'pl:X3ABC',
        'lat': lat0,
        'lon': lon0,
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
    await t.tap(find.text('Message'));
    await settle(t);
    expect(acted, ['pl:X3ABC/message']);
    expect(find.text('Open'), findsNothing, reason: 'the popup closes');
  });

  testWidgets('a pan keeps the same groups (they are per zoom, not per frame)', (t) async {
    final markers = [
      for (var i = 0; i < 300; i++)
        {'id': 'pl:P$i', 'lat': lat0 - 0.1 + (i % 20) * 0.01, 'lon': lon0 - 0.1 + (i ~/ 20) * 0.013, 'label': 'P$i'},
    ];
    await pump(t, markers);
    final before = bubbles()..sort();
    // Pan a little in steps: the groups ride with the map.
    for (var dx = 0; dx < 3; dx++) {
      await t.drag(find.byType(SlippyMap), const Offset(13, 7));
      await t.pump(const Duration(milliseconds: 50));
      final now = bubbles()..sort();
      expect(now, before, reason: 'regrouped by a ${(dx + 1) * 13} px pan');
    }
  });

  testWidgets('a group tapped zooms in where it comes apart, the markers sliding out', (t) async {
    await pump(t, [
      {'id': 'pl:P1', 'lat': lat0, 'lon': lon0 + 100 / k, 'label': 'P1'},
      {'id': 'pl:P2', 'lat': lat0, 'lon': lon0 + 106 / k, 'label': 'P2'},
    ]);
    expect(pins(), 0);
    await t.tap(find.text('2'));
    // The bubble rides the zoom in; at the level where it parts, the two
    // come out of it, close together still, and slide apart.
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 60));
    }
    expect(pins(), 2, reason: 'out of the bubble as the zoom crosses its level');
    final mid = (t.getCenter(find.byKey(const ValueKey('pin_pl:P1'))) -
            t.getCenter(find.byKey(const ValueKey('pin_pl:P2'))))
        .distance;
    await settle(t);
    final end = (t.getCenter(find.byKey(const ValueKey('pin_pl:P1'))) -
            t.getCenter(find.byKey(const ValueKey('pin_pl:P2'))))
        .distance;
    expect(end, greaterThan(mid), reason: 'sliding apart, not jumping');
    expect(end, greaterThan(40), reason: 'apart enough to tap each');
    // Centred on them.
    final p = t.getCenter(find.byKey(const ValueKey('pin_pl:P1')));
    expect(p.dx, inInclusiveRange(80, 320));
    expect(p.dy, inInclusiveRange(150, 550));
  });

  testWidgets('zooming out gathers them back into their group', (t) async {
    await pump(t, [
      {'id': 'pl:Q1', 'lat': lat0, 'lon': lon0, 'label': 'Q1'},
      {'id': 'pl:Q2', 'lat': lat0, 'lon': lon0 + 45 / k, 'label': 'Q2'},
    ], zoom: 12);
    expect(pins(), 2);
    await t.tap(find.byIcon(Icons.remove));
    await t.tap(find.byIcon(Icons.remove));
    await settle(t);
    expect(pins(), 0);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('stations on one point fan out on legs; each opens; a tap on the map folds them', (t) async {
    final tapped = <String>[];
    await pump(t, [
      for (final c in ['X3ONE', 'X3TWO', 'X3SIX', 'X3TEN', 'X1ANA'])
        {
          'id': 'pl:$c',
          'lat': lat0,
          'lon': lon0,
          'label': c,
          'detail': '$c detail',
          'actions': [
            {'id': 'open', 'label': 'Open'},
          ],
        },
    ], onTap: tapped.add);
    await t.tap(find.text('5'));
    await settle(t);
    expect(pins(), 5, reason: 'fanned out');
    for (final c in ['X3ONE', 'X3TWO', 'X3SIX', 'X3TEN', 'X1ANA']) {
      expect(find.text(c), findsOneWidget, reason: 'with its label');
    }
    final centres = [
      for (final c in ['X3ONE', 'X3TWO', 'X3SIX', 'X3TEN', 'X1ANA'])
        t.getCenter(find.byKey(ValueKey('pin_pl:$c')))
    ];
    for (var i = 0; i < centres.length; i++) {
      for (var j = i + 1; j < centres.length; j++) {
        expect((centres[i] - centres[j]).distance, greaterThan(24), reason: 'no two on each other');
      }
    }
    await t.tap(find.text('X3TWO'));
    await settle(t);
    expect(tapped, ['pl:X3TWO']);
    expect(find.text('X3TWO detail'), findsOneWidget, reason: 'its popup, where it is drawn');
    expect(pins(), 5, reason: 'the fan stays open under the popup');
    await t.tapAt(const Offset(30, 650));
    await settle(t);
    expect(pins(), 0, reason: 'folded back into the group');
    expect(find.text('5'), findsOneWidget);
  });

  testWidgets('more on one point than a fan holds: the wapp lists them', (t) async {
    List<String>? listed;
    await pump(t, [
      for (var i = 0; i < 60; i++) {'id': 'pl:Z$i', 'lat': lat0, 'lon': lon0, 'label': 'Z$i'},
    ], onHere: (ids) => listed = ids);
    await t.tap(find.text('60'));
    await settle(t);
    expect(listed?.length, 60);
    expect(pins(), 0);
  });

  testWidgets('without a list to hand them to, they fan out on a spiral', (t) async {
    await pump(t, [
      for (var i = 0; i < 20; i++) {'id': 'pl:S$i', 'lat': lat0, 'lon': lon0, 'label': 'S$i'},
    ]);
    await t.tap(find.text('20'));
    await settle(t);
    expect(pins(), 20);
  });

  testWidgets("an archiver is the yellow square, never inside the others' group", (t) async {
    await pump(t, [
      {'id': 'pl:X3ARCH', 'lat': lat0, 'lon': lon0, 'label': 'X3ARCH', 'kind': 'archive'},
      {'id': 'pl:X1A', 'lat': lat0, 'lon': lon0 + 3 / k, 'label': 'X1A'},
      {'id': 'pl:X1B', 'lat': lat0, 'lon': lon0 + 6 / k, 'label': 'X1B'},
    ]);
    expect(find.byIcon(Icons.inventory_2_outlined), findsOneWidget);
    expect(find.text('X3ARCH'), findsOneWidget);
    expect(find.text('2'), findsOneWidget, reason: 'the two others, apart from it');
    // The group steps aside so both show and both take a tap.
    final a = t.getCenter(find.byIcon(Icons.inventory_2_outlined));
    final b = t.getCenter(find.text('2'));
    expect((a - b).distance, greaterThan(20));
  });

  testWidgets('the group beside an archiver zooms in on its stations, not on where it stepped aside to', (t) async {
    await pump(t, [
      {'id': 'pl:X3ARCH', 'lat': lat0, 'lon': lon0, 'label': 'X3ARCH', 'kind': 'archive'},
      {'id': 'pl:X1A', 'lat': lat0 - 3 / k, 'lon': lon0 + 4 / k, 'label': 'X1A'},
      {'id': 'pl:X1B', 'lat': lat0 + 2 / k, 'lon': lon0 + 6 / k, 'label': 'X1B'},
    ]);
    await t.tap(find.text('2'));
    await settle(t);
    expect(find.text('X1A'), findsOneWidget);
    expect(find.text('X1B'), findsOneWidget);
    expect(find.text('X3ARCH'), findsOneWidget, reason: 'the archiver still in view beside them');
  });

  testWidgets("a fanned marker's popup keeps clear of the fan", (t) async {
    await pump(t, [
      for (final c in ['X3ONE', 'X3TWO', 'X3SIX', 'X3TEN', 'X1ANA'])
        {'id': 'pl:$c', 'lat': lat0, 'lon': lon0, 'label': c, 'detail': '$c detail'},
    ]);
    await t.tap(find.text('5'));
    await settle(t);
    await t.tap(find.text('X3TWO'));
    await settle(t);
    final pop = t.getRect(find.ancestor(of: find.text('X3TWO detail'), matching: find.byType(Container)).first);
    for (final c in ['X3ONE', 'X3SIX', 'X3TEN', 'X1ANA']) {
      expect(pop.overlaps(t.getRect(find.byKey(ValueKey('pin_pl:$c')))), isFalse, reason: '$c covered');
    }
  });

  testWidgets('a locate with an id opens that marker, fanning out its point first', (t) async {
    final markers = [
      for (final c in ['X3A', 'X3B', 'X3C'])
        {'id': 'pl:$c', 'lat': lat0, 'lon': lon0, 'label': c, 'detail': '$c here'},
    ];
    await pump(t, markers);
    expect(pins(), 0);
    await pump(t, markers, openId: 'pl:X3B', openSeq: 1);
    await settle(t);
    expect(pins(), 3);
    expect(find.text('X3B here'), findsOneWidget);
  });

  testWidgets('over a drawer the zoom buttons sit just above its edge, and hide when it covers the map', (t) async {
    Future<void> at(double inset) async {
      t.view.physicalSize = const Size(400, 700);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SlippyMap(
            lat: lat0,
            lon: lon0,
            zoom: 10,
            tileUrl: '',
            showSearch: false,
            minZoom: 2,
            maxZoom: 18,
            onViewportChanged: (_, __, ___) {},
            embedChat: false,
            bottomInset: inset,
          ),
        ),
      ));
      await settle(t);
    }

    await at(80);
    final minus = t.getRect(find.byIcon(Icons.remove));
    expect(minus.bottom, lessThanOrEqualTo(700 - 80), reason: 'above the folded drawer');
    expect(minus.bottom, greaterThan(700 - 80 - 40), reason: 'right above it, not floating mid-map');
    await at(350);
    expect(t.getRect(find.byIcon(Icons.remove)).bottom, lessThanOrEqualTo(350));
    await at(640);
    expect(find.byIcon(Icons.remove), findsNothing, reason: 'the drawer covers the map');
  });

  testWidgets('the filter over the map: segments with counts, a tap says which', (t) async {
    final chosen = <String>[];
    t.view.physicalSize = const Size(400, 700);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SlippyMap(
          lat: lat0,
          lon: lon0,
          zoom: 10,
          tileUrl: '',
          showSearch: false,
          minZoom: 2,
          maxZoom: 18,
          onViewportChanged: (_, __, ___) {},
          embedChat: false,
          filter: const [
            {'id': 'all', 'label': 'All', 'count': 7, 'on': true},
            {'id': 'archive', 'label': 'Archivers', 'count': 2, 'on': false},
            {'id': 'people', 'label': 'People', 'count': 3, 'on': false},
            {'id': 'other', 'label': 'Other', 'count': 2, 'on': false},
          ],
          onFilter: chosen.add,
        ),
      ),
    ));
    await settle(t);
    expect(find.byKey(const ValueKey('map_filter')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('map_filter_archive')));
    expect(chosen, ['archive']);
  });

  testWidgets("a station's popup: its tags as chips, no coordinates; Visit and Keep my messages here", (t) async {
    final acted = <String>[];
    await pump(t, [
      {
        'id': 'pl:X3PTZM',
        'lat': lat0,
        'lon': lon0,
        'label': 'X3PTZM',
        'kind': 'archive',
        'detail': 'XPRS-server\nHeard 3 min ago',
        'tags': ['Archiver', 'Solar'],
        'coords': false,
        'actions': [
          {'id': 'visit', 'label': 'Visit'},
          {'id': 'keep', 'label': 'Keep my messages here'},
        ],
      },
    ], onAction: (id, a) => acted.add(a));
    await t.tap(find.text('X3PTZM'));
    await settle(t);
    expect(find.text('Archiver'), findsOneWidget);
    expect(find.text('Solar'), findsOneWidget);
    expect(find.byIcon(Icons.copy), findsNothing, reason: 'no coordinates to copy');
    await t.tap(find.text('Visit'));
    expect(acted, ['visit']);
  });

  testWidgets('an archiver that keeps my messages is drawn filled', (t) async {
    await pump(t, [
      {'id': 'pl:X3MINE', 'lat': lat0, 'lon': lon0, 'label': 'X3MINE', 'kind': 'archive', 'filled': true},
    ]);
    final icon = t.widget<Icon>(find.byIcon(Icons.inventory_2_outlined));
    expect(icon.color, const Color(0xFF141312), reason: 'dark mark on gold');
  });
}
