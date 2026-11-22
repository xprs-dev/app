// "Share link" on a group: offered on its row menu and in its open header
// where the wapp's rail entry says `share` (a group, open or closed), and it
// hands the group's id back (onShare) for the wapp to show its link. A room
// by range or a person has none.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/conversation_store.dart';
import 'package:xprs/wapp/geoui/widgets/rooms_field.dart';

import 'i18n_english.dart';

void main() {
  installEnglishForTest();

  Future<List<String>> pumpRooms(WidgetTester tester, {String? open}) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = ConversationStore()
      ..upsert({'id': '#X5TOWN', 'title': 'town'})
      ..upsert({'id': '#LISBOA', 'title': 'lisboa'})
      ..upsert({'id': '#LOCAL', 'title': 'local chat'});
    final asked = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RoomsField(
          rooms: const [
            {'id': '#X5TOWN', 'name': 'town', 'share': true},
            {'id': '#LISBOA', 'name': 'lisboa', 'share': true},
            {'id': '#LOCAL', 'name': 'local chat'},
          ],
          store: store,
          openId: open,
          onOpenRoom: (_) {},
          onSend: (_, _) {},
          onNewRoom: (_) {},
          onMembers: () {},
          onArchive: (_) {},
          onShare: asked.add,
        ),
      ),
    ));
    await tester.pump();
    return asked;
  }

  testWidgets('a group with a callsign offers Share link in its menu',
      (tester) async {
    final asked = await pumpRooms(tester);
    await tester.longPress(find.text('town').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share link'));
    await tester.pumpAndSettle();
    expect(asked, ['#X5TOWN']);
  });

  testWidgets('so does an open group by name', (tester) async {
    final asked = await pumpRooms(tester);
    await tester.longPress(find.text('lisboa').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Share link'));
    await tester.pumpAndSettle();
    expect(asked, ['#LISBOA']);
  });

  testWidgets('a room by range has no link to share', (tester) async {
    await pumpRooms(tester);
    await tester.longPress(find.text('local chat').first);
    await tester.pumpAndSettle();
    expect(find.text('Share link'), findsNothing);
  });

  testWidgets('the open group\'s header has the share button', (tester) async {
    final asked = await pumpRooms(tester, open: '#LISBOA');
    await tester.tap(find.byTooltip('Share link'));
    await tester.pump();
    expect(asked, ['#LISBOA']);
  });

  testWidgets('and the open room by range does not', (tester) async {
    await pumpRooms(tester, open: '#LOCAL');
    expect(find.byTooltip('Share link'), findsNothing);
  });
}
