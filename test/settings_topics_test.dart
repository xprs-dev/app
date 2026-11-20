// Settings is a short menu of topics, each opening its own page, and every
// page draws without an error. Hardware's radio dialog starts each kind of
// radio from its own defaults.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xprs/launcher/hardware_page.dart';
import 'package:xprs/launcher/launcher.dart';
import 'package:xprs/services/preferences_service.dart';

import 'i18n_english.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  installEnglishForTest();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTest();
    await PreferencesService.instance();
  });

  Future<void> pump(WidgetTester tester, Widget page) async {
    tester.view.physicalSize = const Size(412 * 3, 900 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: page));
    // The page loads its preferences off the first frame: wait until it has.
    for (var i = 0; i < 50; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
  }

  testWidgets('Settings is a menu of topics, Groups and Hardware among them',
      (tester) async {
    await pump(tester, const IwiSettingsPage());
    for (final t in [
      'This device',
      'Language',
      'Location & privacy',
      'Groups',
      'Hardware',
      'Network',
      'Updates',
      'Storage',
      'Developer',
    ]) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    // The long list of controls is not on the menu any more.
    expect(find.byType(SwitchListTile), findsNothing);
  });

  for (final topic in SettingsTopic.values) {
    testWidgets('the ${topic.name} page draws', (tester) async {
      await pump(tester, IwiSettingsPage(topic: topic));
      expect(tester.takeException(), isNull);
      expect(find.byType(ListView), findsOneWidget);
    });
  }

  testWidgets('Location & privacy holds sharing, coverage and muted accounts',
      (tester) async {
    await pump(tester, const IwiSettingsPage(topic: SettingsTopic.privacy));
    expect(find.text("Share this device's location"), findsOneWidget);
    expect(find.text('Say where this device serves'), findsOneWidget);
    expect(find.text('Muted accounts'), findsOneWidget);
  });

  testWidgets('Hardware no longer holds coverage, and draws', (tester) async {
    await pump(tester, const HardwarePage());
    expect(tester.takeException(), isNull);
    expect(find.text('Say where this device serves'), findsNothing);
  });

  testWidgets('a Bluetooth radio has no frequency to state', (tester) async {
    await pump(tester, const HardwarePage());
    await tester.scrollUntilVisible(find.text('Add a radio').last, 200);
    await tester.tap(find.text('Add a radio').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '868200'), findsOneWidget);
    await tester.tap(find.text('LoRa').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bluetooth').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '868200'), findsNothing,
        reason: 'LoRa\'s frequency stayed on a Bluetooth link');
  });
}
