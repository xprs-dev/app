// The Following tab of an XPRS feed, whose authors are CALLSIGNS.
//
// Social's posts are `t:status` packets: the author is the callsign that signed
// them, not a 64-hex key. The host used to hand this feed the NOSTR contact
// list, which put it on the strict pubkey predicate — that requires a 64-hex
// author, so every XPRS row was rejected and the tab rendered "Nothing from
// people you follow yet" over a full archive, however many people you followed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/wapp/geoui/widgets/activity_feed.dart';

Map<String, dynamic> _post(String from, String text,
        {String dir = 'in', String? mid}) =>
    {
      'from': from,
      'author': from,
      'text': text,
      'mid': mid ?? '${from}_${text.hashCode}',
      'dir': dir,
      't': DateTime.now().millisecondsSinceEpoch,
      'source': 'xprs',
    };

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  final posts = [
    _post('X1ARKL', 'a friend speaks'),
    _post('X3ZZZZ', 'a stranger speaks'),
    _post('X16JK8', 'my own words', dir: 'out'),
  ];

  testWidgets('Following shows the callsigns you follow, and your own posts',
      (tester) async {
    await _pump(
      tester,
      ActivityFeed(
        posts: posts,
        onSend: (_) {},
        followedCalls: const {'X1ARKL'},
        initialFilter: 'following',
      ),
    );

    expect(find.text('a friend speaks'), findsOneWidget);
    expect(find.text('my own words'), findsOneWidget,
        reason: 'your own posts belong in the conversation you follow');
    expect(find.text('a stranger speaks'), findsNothing);
  });

  testWidgets('a post archived BEFORE the follow is in the tab', (tester) async {
    // The point of filtering the one archive at read time rather than keeping a
    // second one fed at arrival: following somebody is retroactive, because the
    // posts were already kept. The old second archive could only ever hold what
    // came in after the follow.
    await _pump(
      tester,
      ActivityFeed(
        posts: posts, // the same rows, archived long before
        onSend: (_) {},
        followedCalls: const {'X1ARKL'},
        initialFilter: 'following',
      ),
    );
    expect(find.text('a friend speaks'), findsOneWidget);
  });

  testWidgets('following nobody shows the empty state, not the mesh',
      (tester) async {
    await _pump(
      tester,
      ActivityFeed(
        posts: posts,
        onSend: (_) {},
        initialFilter: 'following',
      ),
    );
    expect(find.text('a stranger speaks'), findsNothing);
    expect(find.text('a friend speaks'), findsNothing);
    expect(find.text('my own words'), findsOneWidget,
        reason: 'what you said is yours whether or not you follow anybody');
  });

  testWidgets('Mesh shows everyone', (tester) async {
    await _pump(
      tester,
      ActivityFeed(
        posts: posts,
        onSend: (_) {},
        followedCalls: const {'X1ARKL'},
        initialFilter: 'all',
      ),
    );
    expect(find.text('a friend speaks'), findsOneWidget);
    expect(find.text('a stranger speaks'), findsOneWidget);
  });
}
