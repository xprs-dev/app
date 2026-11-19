// "New folder" on a group: offered on its row menu and in its open header
// only where the wapp's rail entry says `nest`, and it hands the group's id
// back (onNewRoom). A public group's admin had no way to it but the member
// panel.
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
      ..upsert({'id': '#X5CLUB', 'title': 'club'});
    final asked = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RoomsField(
          rooms: const [
            {'id': '#X5TOWN', 'name': 'town', 'nest': true},
            {'id': '#X5CLUB', 'name': 'club'},
          ],
          store: store,
          openId: open,
          onOpenRoom: (_) {},
          onSend: (_, _) {},
          onNewRoom: asked.add,
          onMembers: () {},
          onArchive: (_) {},
        ),
      ),
    ));
    await tester.pump();
    return asked;
  }

  testWidgets('a group the wapp lets us nest in offers New folder',
      (tester) async {
    final asked = await pumpRooms(tester);
    await tester.longPress(find.text('town').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('New folder'));
    await tester.pumpAndSettle();
    expect(asked, ['#X5TOWN']);
  });

  testWidgets('a group without nest has no New folder', (tester) async {
    await pumpRooms(tester);
    await tester.longPress(find.text('club').first);
    await tester.pumpAndSettle();
    expect(find.text('New folder'), findsNothing);
  });

  testWidgets('the open group header has the folder button', (tester) async {
    final asked = await pumpRooms(tester, open: '#X5TOWN');
    await tester.tap(find.byTooltip('New folder'));
    await tester.pump();
    expect(asked, ['#X5TOWN']);
  });

  testWidgets('and not where the wapp did not say nest', (tester) async {
    await pumpRooms(tester, open: '#X5CLUB');
    expect(find.byTooltip('New folder'), findsNothing);
  });
}
