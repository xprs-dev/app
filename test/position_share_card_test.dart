// Settings > Location: sharing reads as on with the 100 km range, the code
// that opens the hidden digits is there to copy, and a new code replaces it.
// What goes on the air is the core's (core/test/xprs_shared_position_test.dart).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xprs/launcher/position_share_card.dart';
import 'package:xprs/services/preferences_service.dart';
import 'package:xprs_core/src/services/xprs/xprs_shared_position.dart';

void main() {
  final said = <String>[];
  String? copied;

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'position.share': true,
      'position.fixed': '38.7077,-9.1365',
    });
    PreferencesService.resetForTest();
    await PreferencesService.instance();
    said.clear();
    copied = null;
    final sp = XprsSharedPosition.instance..debugReset();
    sp.announce = (pos, acc) => said.add('$pos $acc');
    sp.redact = (job) async => xprsPosRedactCompute(job);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
  });

  Future<void> open(WidgetTester t) async {
    await t.pumpWidget(const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: PositionShareCard())),
    ));
    await t.runAsync(() => XprsSharedPosition.instance.refresh());
    await t.pump();
  }

  testWidgets('a range never chosen is 100 km, and only the degrees are said',
      (t) async {
    await open(t);
    expect(find.textContaining('100 km'), findsWidgets);
    expect(said.last, '38█████,-9█████ 100000');
    final c = XprsSharedPosition.instance.current()!;
    expect(c.pos, '38█████,-9█████');
    expect(c.xr, isNotNull, reason: 'the rest is there for whoever has the code');
  });

  testWidgets('the code is generated, copied as it stands, and replaced whole',
      (t) async {
    await open(t);
    final code = PreferencesService.instanceSync!.positionCode;
    expect(code, matches(RegExp(r'^[A-Z2-9]{4}(-[A-Z2-9]{4}){3}$')));
    expect(find.text(code), findsOneWidget);

    await t.tap(find.byIcon(Icons.copy));
    await t.pump();
    expect(copied, code);

    await t.runAsync(() async {
      await t.tap(find.byIcon(Icons.refresh));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await t.pump();
    final next = PreferencesService.instanceSync!.positionCode;
    expect(next, isNot(code));
    expect(find.text(next), findsOneWidget);
    expect(find.text(code), findsNothing);
  });

  testWidgets('switched off, nothing is said and the code is put away', (t) async {
    await open(t);
    await t.tap(find.byType(Switch));
    await t.runAsync(() => XprsSharedPosition.instance.refresh());
    await t.pump();
    expect(PreferencesService.instanceSync!.positionShare, isFalse);
    expect(XprsSharedPosition.instance.current(), isNull);
    expect(said.last, ' 0');
    expect(find.byIcon(Icons.copy), findsNothing);
  });
}
