// Settings is a short menu of topics, each opening its own page, and every
// page draws without an error. Hardware's radio dialog starts each kind of
// radio from its own defaults.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xprs/launcher/archiver_page.dart';
import 'package:xprs/launcher/hardware_page.dart';
import 'package:xprs/launcher/launcher.dart';
import 'package:xprs/services/preferences_service.dart';
import 'package:xprs_core/src/services/social/node_role_api.dart';

import 'i18n_english.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  installEnglishForTest();

  // Once for the file: the store is a process-wide singleton, and reset
  // between tests a page's second load never completes in the test binding.
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    PreferencesService.resetForTest();
    await PreferencesService.instance();
    // The core's serve counters start a minute timer on first use: start it
    // here, outside a test's fake clock, or the Archiver test leaves it pending.
    NodeRoleApi.instance.serveRings;
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

  // One walk through Settings, as a person would take it: the menu, then
  // each topic opened from it and closed again. (Separate tests would each
  // build a fresh page against singletons the previous test left behind.)
  testWidgets('Settings is a menu of topics, and each opens its own page',
      (tester) async {
    await pump(tester, const IwiSettingsPage());
    for (final t in [
      'This device', 'Language', 'Location & privacy', 'Groups', 'Hardware',
      'Network', 'Updates', 'Storage', 'Developer',
    ]) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    // The long list of controls is not on the menu any more.
    expect(find.byType(SwitchListTile), findsNothing);

    for (final t in [
      'This device', 'Language', 'Location & privacy', 'Network', 'Updates',
      'Storage', 'Developer',
    ]) {
      await tester.tap(find.text(t));
      await tester.pumpAndSettle();
      for (var i = 0; i < 50; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
        if (find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
      }
      expect(tester.takeException(), isNull, reason: t);
      expect(find.byType(CircularProgressIndicator), findsNothing,
          reason: '$t is still loading');
      expect(find.widgetWithText(AppBar, t), findsOneWidget, reason: t);
      if (t == 'Network') {
        // Hosting lives on the Archiver page (Files), not here.
        expect(find.text('Host for the mesh'), findsNothing);
        expect(find.byType(SwitchListTile), findsNothing);
      }
      if (t == 'Location & privacy') {
        // Everything about where this station is, in one place.
        expect(find.text("Share this device's location"), findsOneWidget);
        expect(find.text('Say where this device serves'), findsOneWidget);
        expect(find.text('Muted accounts'), findsOneWidget);
      }
      await tester.pageBack();
      await tester.pumpAndSettle();
    }
  });

  testWidgets('Hardware no longer holds coverage, and draws', (tester) async {
    await pump(tester, const HardwarePage());
    expect(tester.takeException(), isNull);
    expect(find.text('Say where this device serves'), findsNothing);
  });

  testWidgets('a Bluetooth radio has no frequency to state', (tester) async {
    await pump(tester, const HardwarePage());
    await tester.scrollUntilVisible(find.text('Add a radio'), 200,
        scrollable: find.byType(Scrollable).first);
    // Fully on screen, not just its top edge, or the tap lands below it.
    await tester.ensureVisible(find.text('Add a radio'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add a radio'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.widgetWithText(TextFormField, '868200'), findsOneWidget);
    await tester.tap(find.text('LoRa').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Bluetooth').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '868200'), findsNothing,
        reason: 'LoRa\'s frequency stayed on a Bluetooth link');
  });

  testWidgets('the Archiver Files tab holds the hosting switches',
      (tester) async {
    await pump(tester, const ArchiverPage());
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Hosting'), findsOneWidget);
    expect(find.text('Storage for media'), findsOneWidget);

    final prefs = PreferencesService.instanceSync!;
    expect(prefs.hostEnabled, isTrue);
    await tester.tap(find.widgetWithText(SwitchListTile, 'Host for the mesh'));
    await tester.pumpAndSettle();
    expect(prefs.hostEnabled, isFalse);
    // Off: the charging gate has nothing to gate.
    expect(
        tester
            .widget<SwitchListTile>(find.widgetWithText(
                SwitchListTile, 'Only when charging on Wi-Fi'))
            .onChanged,
        isNull);
    prefs.hostEnabled = true;
    // Close the page: its once-a-minute refresh timer ends with it.
    await tester.pumpWidget(const SizedBox());
  });
}
