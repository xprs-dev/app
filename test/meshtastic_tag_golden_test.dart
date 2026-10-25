// A bridged Meshtastic sender wears a MESHTASTIC tag beside the bearer chip,
// and its message Info shows the relay path (who carried it here). Renders the
// real ChatViewField headlessly and captures goldens -- the desktop GUI could
// not be built/driven in this environment (no Wayland input tooling).
import 'dart:io';
import 'package:xprs/wapp/geoui/widgets/chat_view_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'i18n_english.dart';

// flutter test renders text as boxes unless real fonts are loaded; load the
// Roboto + MaterialIcons that ship with the Flutter SDK so the goldens read.
// The goldens were drawn on a dev machine with these fonts and its Flutter.
// Where the fonts cannot be found, or on CI (which follows the newest stable
// Flutter, whose text rendering moves by a few pixels), the widget assertions
// still run and only the pixel comparison is skipped.
var _fontsLoaded = false;

Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'] ??
      '${Platform.environment['HOME']}/flutter';
  final cache = '$root/bin/cache/artifacts/material_fonts';
  _fontsLoaded = File('$cache/Roboto-Regular.ttf').existsSync() &&
      Platform.environment['CI'] == null;
  Future<void> add(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final file = File('$cache/$f');
      if (file.existsSync()) {
        loader.addFont(
            Future.value(file.readAsBytesSync().buffer.asByteData()));
      }
    }
    await loader.load();
  }

  await add('Roboto',
      ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
  await add('MaterialIcons', ['MaterialIcons-Regular.otf']);
}

void main() {
  installEnglishForTest();
  setUpAll(_loadFonts);

  Future<void> pump(WidgetTester t, List<Map<String, dynamic>> m,
      {Size size = const Size(620, 420)}) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Roboto'),
      home: Scaffold(
        backgroundColor: const Color(0xFF0B0F14),
        body: ChatViewField(
          fieldName: 'chat',
          label: 'Global chat',
          fill: true,
          messages: m,
          onSend: (_) {},
        ),
      ),
    ));
    await t.pumpAndSettle();
  }

  // One of ours (an X1 person, heard over the LAN) and a Meshtastic node
  // bridged in over BLE, relayed here by the station X3SEP2.
  final ours = <String, dynamic>{
    'dir': 'in',
    'from': 'X1A33T',
    'text': 'Yo!',
    'time': '21:01',
    'via': 'LAN',
    'auth': 'verified',
  };
  final mt = <String, dynamic>{
    'dir': 'in',
    'from': 'MT66B7F06F',
    'text': 'Boa noite malta',
    'time': '21:04',
    'via': 'BLE',
    'net': 'Meshtastic',
    'path': 'X3SEP2',
  };

  testWidgets('a bridged Meshtastic bubble wears a MESHTASTIC tag', (t) async {
    await pump(t, [ours, mt]);
    expect(find.text('MESHTASTIC'), findsOneWidget);
    expect(find.text('BLE'), findsOneWidget);
    if (_fontsLoaded) {
      await expectLater(find.byType(ChatViewField),
          matchesGoldenFile('goldens/meshtastic_bubble.png'));
    }
  });

  testWidgets('message Info shows the relay path provenance', (t) async {
    await pump(t, [mt], size: const Size(620, 860));
    await t.tap(find.byIcon(Icons.more_vert).last);
    await t.pumpAndSettle();
    await t.tap(find.text('Info'));
    await t.pumpAndSettle();
    expect(find.text('Network'), findsOneWidget);
    expect(find.text('Meshtastic'), findsWidgets);
    expect(find.text('Relayed via'), findsOneWidget);
    expect(find.text('X3SEP2'), findsOneWidget);
    if (_fontsLoaded) {
      await expectLater(find.byType(Dialog),
          matchesGoldenFile('goldens/meshtastic_info.png'));
    }
  });
}
