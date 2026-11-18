// Changing the station's own X3 (Settings > This device, the Archiver page):
// a candidate is shown, "another one" rolls a new one, "back" returns to the
// previous one, and Save makes the device wear the one shown.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/reticulum.dart' show NostrKeyGenerator;
import 'package:xprs/launcher/device_identity_card.dart';
import 'package:xprs_core/src/profile/device_identity.dart';
import 'package:xprs_core/src/profile/storage_paths.dart';

String _shownCallsign(WidgetTester tester) {
  // The candidate is the one headline-sized text that starts X3.
  final t = tester
      .widgetList<Text>(find.byType(Text))
      .map((w) => w.data ?? '')
      .where((s) => RegExp(r'^X3[A-Z0-9]+$').hasMatch(s));
  return t.single;
}

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('station_call');
    setStorageRootForTest(dir.path);
    DeviceIdentity.instance
      ..resetForTest()
      ..adoptForTest(NostrKeyGenerator.generateKeyPair().nsec);
  });
  tearDown(() {
    DeviceIdentity.instance.resetForTest();
    dir.deleteSync(recursive: true);
  });

  testWidgets('roll, go back, save: the device wears the one shown',
      (tester) async {
    final before = DeviceIdentity.instance.callsign;
    bool? saved;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => saved = await changeStationCallsign(context),
            child: const Text('go'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();

    final first = _shownCallsign(tester);
    expect(first, isNot(before));
    final back = find.byIcon(Icons.undo);
    expect(tester.widget<IconButton>(find.ancestor(
        of: back, matching: find.byType(IconButton))).onPressed, isNull,
        reason: 'nothing to go back to yet');

    await tester.tap(find.byIcon(Icons.autorenew));
    await tester.pumpAndSettle();
    final second = _shownCallsign(tester);
    expect(second, isNot(first));

    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(_shownCallsign(tester), first);

    // Save writes the key (real file I/O), then offers the restart.
    await tester.tap(find.byType(FilledButton));
    for (var i = 0;
        i < 40 && DeviceIdentity.instance.callsign != first;
        i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(DeviceIdentity.instance.callsign, first);
    await tester.tap(find.byType(TextButton).last); // Later
    await tester.pumpAndSettle();
    expect(saved, isTrue);
  });
}
