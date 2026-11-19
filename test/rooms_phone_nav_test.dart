// Groups on a phone: the conversation list shows groups and people only; a
// group that has folders opens on its own list (its conversation first, as
// "General", then its folders by their own names); adding a folder is in
// the bar's menu, never a row; and the tree reads as a path for the bar.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/conversation_store.dart';
import 'package:xprs/wapp/geoui/widgets/rooms_field.dart';

import 'i18n_english.dart';

const _rows = <Map<String, dynamic>>[
  {'id': '#X5FAMI', 'name': 'Family', 'nest': true},
  {'id': '#X5RECI', 'name': 'Family › Recipes', 'parent': '#X5FAMI', 'depth': 1, 'nest': true},
  {'id': '#X5SOUP', 'name': 'Family › Recipes › Soups', 'parent': '#X5RECI', 'depth': 2},
  {'id': '#X5CLUB', 'name': 'Club', 'nest': true},
  {'id': 'X1FRND', 'name': 'X1FRND'},
];

void main() {
  installEnglishForTest();

  Future<({List<String> opened, List<String?> browsed, List<String> made})>
      pump(WidgetTester tester, {String? browse, String? open}) async {
    tester.view.physicalSize = const Size(360, 760);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = ConversationStore();
    for (final r in _rows) {
      store.upsert({'id': r['id'], 'title': r['name']});
    }
    final opened = <String>[], made = <String>[];
    final browsed = <String?>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RoomsField(
          rooms: _rows,
          store: store,
          openId: open,
          browseId: browse,
          onBrowse: browsed.add,
          hostHeader: true,
          onOpenRoom: opened.add,
          onSend: (_, _) {},
          onNewRoom: made.add,
          onMembers: () {},
          onArchive: (_) {},
        ),
      ),
    ));
    await tester.pump();
    return (opened: opened, browsed: browsed, made: made);
  }

  testWidgets('the list shows groups and people, not what is inside a group',
      (tester) async {
    await pump(tester);
    expect(find.text('Family'), findsOneWidget);
    expect(find.text('Club'), findsOneWidget);
    expect(find.text('X1FRND'), findsOneWidget);
    expect(find.textContaining('Recipes'), findsNothing);
    expect(find.textContaining('Soups'), findsNothing);
  });

  testWidgets('a group with folders opens on its list, any other opens',
      (tester) async {
    final r = await pump(tester);
    await tester.tap(find.text('Family'));
    await tester.tap(find.text('Club'));
    await tester.tap(find.text('X1FRND'));
    expect(r.browsed, ['#X5FAMI']);
    expect(r.opened, ['#X5CLUB', 'X1FRND']);
  });

  testWidgets('no New folder from the list: a folder is made inside',
      (tester) async {
    await pump(tester);
    await tester.longPress(find.text('Club'));
    await tester.pumpAndSettle();
    expect(find.text('New folder'), findsNothing);
  });

  testWidgets('inside a group: General and its folders by name, nothing else',
      (tester) async {
    final r = await pump(tester, browse: '#X5FAMI');
    expect(find.text('General'), findsOneWidget);
    expect(find.text('Recipes'), findsOneWidget, reason: 'its own name');
    expect(find.text('Club'), findsNothing);
    expect(find.textContaining('Soups'), findsNothing, reason: 'one level');

    await tester.tap(find.text('General'));
    expect(r.opened, ['#X5FAMI'], reason: "the group's own conversation");
    await tester.tap(find.text('Recipes'));
    expect(r.browsed, ['#X5RECI'], reason: 'it has folders of its own');
    // Adding a folder is in the bar's menu (the host's), not a row here.
    expect(find.text('New folder'), findsNothing);
    expect(r.made, isEmpty);
  });

  testWidgets('a folder with nothing inside opens as a conversation',
      (tester) async {
    final r = await pump(tester, browse: '#X5RECI');
    await tester.tap(find.text('Soups'));
    expect(r.opened, ['#X5SOUP']);
    expect(r.browsed, isEmpty);
  });

  testWidgets('an open room draws no header of its own under the bar',
      (tester) async {
    await pump(tester, open: '#X5CLUB');
    expect(find.byTooltip('Members'), findsNothing);
    expect(find.byTooltip('New folder'), findsNothing);
  });

  test('the tree reads as a path, and a folder by its own name', () {
    expect([for (final r in roomsPath(_rows, '#X5SOUP')) r['id']],
        ['#X5FAMI', '#X5RECI', '#X5SOUP']);
    expect(roomsPath(_rows, '#X5CLUB').single['id'], '#X5CLUB');
    expect(roomsPath(_rows, '#NOWHERE'), isEmpty);
    expect([for (final r in roomsKids(_rows, '#X5FAMI')) r['id']], ['#X5RECI']);
    expect(roomsKids(_rows, '#X5SOUP'), isEmpty);
    expect(roomsLeaf('Family › Recipes › Soups'), 'Soups');
    expect(roomsLeaf('Club'), 'Club');
  });
}
