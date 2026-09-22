// A `$type:"image"` field is not always an avatar.
//
// The Things wapp fetches a still off a camera on the LAN and hands it over
// as a data: URI. Drawn the old way that was a 120 px circle with a "Choose
// picture" button over it — a crop that loses the doorstep, and an offer the
// screen cannot honour, because the picture came from the camera and not
// from a file the person picks.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/geoui_parser.dart';
import 'package:xprs/wapp/geoui/geoui_renderer.dart';

class _Bindings extends GeoUiBindings {
  final Map<String, dynamic> values;
  _Bindings(this.values);
  @override
  dynamic getValue(String name) => values[name];
  @override
  void setValue(String name, dynamic v) => values[name] = v;
}

/// A one-screen .ui.json carrying one image field with [attrs].
String screenWith(String attrs) => '''
[{"\$":"screen","name":"Thing","children":[
  {"\$":"field","name":"th_pic","\$type":"image","label":"Picture"$attrs}
]}]''';

/// A 1x1 PNG, so the widget under test has something real to decode.
final onePixel = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==');

void main() {
  Future<void> pump(WidgetTester tester, String attrs,
      {String value = ''}) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final file = GeoUiParser(screenWith(attrs)).parse();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: GeoUiScreenRenderer(
            screen: file.firstScreen!,
            bindings: _Bindings({'th_pic': value}),
            // The host resolves the value; one real pixel is enough here.
            resolveImage: (v) => v.isEmpty ? null : MemoryImage(onePixel),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets('an avatar keeps its circle and its button', (tester) async {
    await pump(tester, '');
    expect(find.text('Choose picture'), findsOneWidget);
    expect(find.byType(AspectRatio), findsNothing);
  });

  testWidgets('readonly drops the button the screen cannot honour',
      (tester) async {
    await pump(tester, ',"readonly":true');
    expect(find.text('Choose picture'), findsNothing);
    expect(find.text('Change picture'), findsNothing);
  });

  testWidgets('wide draws the whole doorstep, not a crop of it',
      (tester) async {
    await pump(tester, ',"shape":"wide","readonly":true',
        value: 'data:image/jpeg;base64,/9j/');
    final box = tester.widget<AspectRatio>(find.byType(AspectRatio));
    expect(box.aspectRatio, closeTo(16 / 9, 0.001));
    expect(find.text('Choose picture'), findsNothing);
    // and it is the value the wapp set that gets resolved, not a placeholder
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('wide with nothing yet shows a placeholder, not a broken box',
      (tester) async {
    await pump(tester, ',"shape":"wide","readonly":true');
    expect(find.byType(AspectRatio), findsOneWidget);
    expect(find.byIcon(Icons.photo_camera_outlined), findsOneWidget);
  });
}
