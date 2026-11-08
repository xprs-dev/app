// A chat room's notifications switch: the row menu and the open room's
// header offer it, label it by the row's muted flag, and hand the id back.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/conversation_store.dart';
import 'package:xprs/wapp/geoui/widgets/rooms_field.dart';

import 'i18n_english.dart';

void main() {
  installEnglishForTest();

  Future<List<String>> pumpRooms(WidgetTester tester,
      {required bool globalMuted, String? open}) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = ConversationStore()
      ..upsert({'id': '#GLOBAL', 'title': 'Global chat', 'muted': globalMuted})
      ..upsert({'id': '#LOCAL', 'title': 'Local chat', 'muted': false});
    final toggled = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RoomsField(
          rooms: const [
            {'id': '#LOCAL', 'name': 'Local chat'},
            {'id': '#GLOBAL', 'name': 'Global chat'},
          ],
          store: store,
          openId: open,
          onOpenRoom: (_) {},
          onSend: (_, _) {},
          onNewRoom: (_) {},
          onMembers: () {},
          onArchive: (_) {},
          onToggleNotify: toggled.add,
        ),
      ),
    ));
    await tester.pump();
    return toggled;
  }

  testWidgets('a muted room offers to turn notifications on', (tester) async {
    final toggled = await pumpRooms(tester, globalMuted: true);
    await tester.longPress(find.text('Global chat').first);
    await tester.pumpAndSettle();
    expect(find.text('Turn on notifications'), findsOneWidget);
    await tester.tap(find.text('Turn on notifications'));
    await tester.pumpAndSettle();
    expect(toggled, ['#GLOBAL']);
  });

  testWidgets('a room that notifies offers to mute', (tester) async {
    final toggled = await pumpRooms(tester, globalMuted: true);
    await tester.longPress(find.text('Local chat').first);
    await tester.pumpAndSettle();
    expect(find.text('Mute notifications'), findsOneWidget);
    await tester.tap(find.text('Mute notifications'));
    await tester.pumpAndSettle();
    expect(toggled, ['#LOCAL']);
  });

  testWidgets('a muted row shows a bell, and the open room has the switch',
      (tester) async {
    final toggled =
        await pumpRooms(tester, globalMuted: true, open: '#GLOBAL');
    expect(find.byTooltip('Notifications off'), findsOneWidget);
    await tester.tap(find.byTooltip('Turn on notifications'));
    await tester.pump();
    expect(toggled, ['#GLOBAL']);
  });
}
