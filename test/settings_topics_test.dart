// Settings is a short menu of topics, each opening its own page, and every
// page draws without an error. The Archiver page's one switch sets all of
// its parts.
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
        // Hosting lives on the Archiver page, not here.
        expect(find.text('Host files for others'), findsNothing);
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

  testWidgets('Hardware states energy and internet, and has no radios',
      (tester) async {
    await pump(tester, const HardwarePage());
    expect(tester.takeException(), isNull);
    expect(find.text('Type of device'), findsOneWidget);
    expect(find.text('Energy source'), findsOneWidget);
    expect(find.text('Add a radio'), findsNothing);
  });

  testWidgets('the Archiver has three tabs and one switch for all of it',
      (tester) async {
    await pump(tester, const ArchiverPage());
    expect(tester.takeException(), isNull);
    for (final t in ['Overview', 'Settings', 'Backup']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    final prefs = PreferencesService.instanceSync!;
    final main = find.widgetWithText(SwitchListTile, 'Archiver');
    if (tester.widget<SwitchListTile>(main).value) {
      await tester.tap(main);
      await tester.pumpAndSettle();
    }
    expect(prefs.xprsPublicArchiver, isFalse);
    expect(prefs.archiveQuotaGb, 0);
    expect(prefs.archiverVolunteer, 'off');
    await tester.tap(main);
    await tester.pumpAndSettle();
    expect(prefs.xprsPublicArchiver, isTrue);
    expect(prefs.archiveQuotaGb, greaterThan(0));
    expect(prefs.archiverVolunteer, isNot('off'));

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(find.text('Share the file index'), 200,
        scrollable: find
            .byWidgetPredicate((w) =>
                w is Scrollable && w.axisDirection == AxisDirection.down)
            .last);
    expect(find.text('Share the file index'), findsOneWidget);

    await tester.tap(find.text('Backup'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    // Close the page: its once-a-minute refresh timer ends with it.
    await tester.pumpWidget(const SizedBox());
  });
}
