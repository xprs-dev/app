// XPRS.md 7.8 on a Status post card: the author corrects or withdraws their own
// post from its menu, an edited one says so, and a withdrawn one keeps its
// place without its words.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/widgets/activity_feed.dart';

Widget _card(Map<String, dynamic> post,
        {List<String>? taps, bool withHandlers = true}) =>
    MaterialApp(
      home: Scaffold(
        body: ActivityPostCard(
          post: post,
          onEdit: withHandlers ? (p) => taps?.add('edit') : null,
          onUnsend: withHandlers ? (p) => taps?.add('unsend') : null,
          onHistory: withHandlers ? (p) => taps?.add('history') : null,
          onBlock: (_) {},
        ),
      ),
    );

Map<String, dynamic> _post({String dir = 'out', Map<String, dynamic>? more}) => {
      'mid': 'aa1111',
      'from': 'X1SELF',
      'dir': dir,
      'text': 'meet at seven',
      'time': '09:30',
      't': DateTime.now().millisecondsSinceEpoch,
      ...?more,
    };

void main() {
  testWidgets('our own post offers Edit and Delete for everyone', (t) async {
    final taps = <String>[];
    await t.pumpWidget(_card(_post(), taps: taps));
    await t.tap(find.byIcon(Icons.more_horiz));
    await t.pumpAndSettle();
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Delete for everyone'), findsOneWidget);
    expect(find.text('Edit history'), findsNothing, reason: 'never edited');
    expect(find.textContaining('Block'), findsNothing,
        reason: 'you do not block yourself');
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    expect(taps, ['edit']);
  });

  testWidgets("somebody else's post offers none of them", (t) async {
    await t.pumpWidget(_card(_post(dir: 'in', more: {'from': 'X1FRND'})));
    await t.tap(find.byIcon(Icons.more_horiz));
    await t.pumpAndSettle();
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Delete for everyone'), findsNothing);
    expect(find.textContaining('Block'), findsOneWidget);
  });

  testWidgets('an edited post says edited and lists its history', (t) async {
    final taps = <String>[];
    await t.pumpWidget(
        _card(_post(more: {'edited': true}), taps: taps));
    expect(find.text('edited'), findsOneWidget);
    await t.tap(find.byIcon(Icons.more_horiz));
    await t.pumpAndSettle();
    await t.tap(find.text('Edit history'));
    await t.pumpAndSettle();
    expect(taps, ['history']);
  });

  testWidgets('the state survives a restart through the archive kind',
      (t) async {
    await t.pumpWidget(_card(_post(more: {'kind': 'msg:edited'})));
    expect(find.text('edited'), findsOneWidget);
  });

  testWidgets('a withdrawn post keeps its place and loses its words',
      (t) async {
    await t.pumpWidget(_card(_post(more: {'deleted': true, 'text': ''})));
    expect(find.text('This post was deleted.'), findsOneWidget);
    expect(find.text('meet at seven'), findsNothing);
    expect(find.byIcon(Icons.more_horiz), findsNothing,
        reason: 'nothing left to edit or withdraw');
  });
}
