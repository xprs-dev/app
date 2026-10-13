// Labels on a narrow phone with large system text.
//
// The Archiver's "Forget strangers after" drew four equal segments on a 360dp
// C61 at font scale 1.3, and "three months" came out as "three / month / s".
// A choice that does not fit its share now wraps as chips. And the Firmwares
// first screen was a grey caption; with `empty_title` and `empty_art` it is a
// page with a drawing that says what a station is.
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/geoui_parser.dart';
import 'package:xprs/wapp/geoui/geoui_renderer.dart';
import 'package:xprs/wapp/geoui/widgets/people_view_field.dart';

class _Bindings extends GeoUiBindings {
  final Map<String, dynamic> values;
  _Bindings(this.values);
  @override
  dynamic getValue(String name) => values[name];
  @override
  void setValue(String name, dynamic v) => values[name] = v;
}

String enumScreen(List<String> labels) => '''
[{"\$":"screen","name":"S","children":[
  {"\$":"field","name":"keep","\$type":"enum","label":"Forget strangers after",
   "children":[${[
      for (var i = 0; i < labels.length; i++)
        '{"\$":"option","name":"o$i","label":"${labels[i]}"}'
    ].join(',')}]}
]}]''';

void main() {
  Future<void> pumpEnum(WidgetTester tester, List<String> labels,
      {double width = 360, double scale = 1.3}) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final file = GeoUiParser(enumScreen(labels)).parse();
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          textScaler: TextScaler.linear(scale),
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            child: GeoUiScreenRenderer(
              screen: file.firstScreen!,
              bindings: _Bindings({'keep': 'o0'}),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('long choices on a narrow phone wrap as chips', (tester) async {
    await pumpEnum(
        tester, ['a week', 'a month', 'three months', 'a year']);
    expect(find.byType(SegmentedButton<String>), findsNothing);
    expect(find.byType(ChoiceChip), findsNWidgets(4));
    expect(find.text('three months'), findsOneWidget);
  });

  testWidgets('short choices keep the segmented bar', (tester) async {
    await pumpEnum(tester, ['5', '20', '50'], scale: 1.0, width: 600);
    expect(find.byType(SegmentedButton<String>), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets('chips still choose and report the value', (tester) async {
    await pumpEnum(
        tester, ['a week', 'a month', 'three months', 'a year']);
    await tester.tap(find.text('a year'));
    await tester.pump();
    final chip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'a year'));
    expect(chip.selected, isTrue);
  });

  group('people empty state', () {
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">'
        '<rect width="10" height="10" fill="#29B6F6"/></svg>';

    Future<void> pumpPeople(WidgetTester tester,
        {String? title, String? art, List<String>? asked}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PeopleViewField(
            fieldName: 'stations',
            sections: const [],
            onTap: (_) {},
            onAction: (_, _) {},
            emptyText: 'A station is a small XPRS board.',
            emptyTitle: title,
            emptyArt: art,
            loadAsset: (p) async {
              asked?.add(p);
              return svg;
            },
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('a titled empty state shows its drawing and heading',
        (tester) async {
      final asked = <String>[];
      await pumpPeople(tester,
          title: 'No station yet', art: 'media/art/stations.svg', asked: asked);
      expect(find.text('No station yet'), findsOneWidget);
      expect(find.text('A station is a small XPRS board.'), findsOneWidget);
      expect(find.byType(SvgPicture), findsOneWidget);
      // read once, not on every build
      await tester.pump();
      expect(asked, ['media/art/stations.svg']);
    });

    testWidgets('without the new keys it is the plain caption it was',
        (tester) async {
      await pumpPeople(tester);
      expect(find.text('A station is a small XPRS board.'), findsOneWidget);
      expect(find.byType(SvgPicture), findsNothing);
    });
  });
}
