// The chat composer's contract with the wapp: what a heart and a reply put on
// the wire, and what must never reach the timeline as text.
//
// Both halves shipped broken on a 1:1 conversation — the heart did nothing at
// all, and a reply rendered its wire marker verbatim, as a bubble reading
// "+9eb53a4af55e5da04cdcc44842502041e8d5e2460f123358c31a17f8a31993dd OK".
import 'package:xprs/wapp/geoui/conversation_store.dart';
import 'package:xprs/wapp/geoui/widgets/chat_view_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> msg(
  String text, {
  String dir = 'in',
  String from = 'X1A33T',
  String mid = '',
  String parent = '',
  int likes = 0,
  bool liked = false,
}) =>
    {
      'dir': dir,
      'from': from,
      'text': text,
      'time': '13:33',
      if (mid.isNotEmpty) 'mid': mid,
      if (parent.isNotEmpty) 'parent': parent,
      if (likes > 0) 'likes': likes,
      if (liked) 'liked': true,
    };

void main() {
  late List<String> sent;

  Future<void> pump(WidgetTester tester, List<Map<String, dynamic>> messages,
      {Size size = const Size(1000, 800)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatViewField(
          fieldName: 'chat',
          label: 'Chat',
          fill: true,
          messages: messages,
          onSend: sent.add,
        ),
      ),
    ));
    await tester.pump();
  }

  setUp(() => sent = <String>[]);

  group('votes never render as messages', () {
    testWidgets('a 4-hex vote is not a bubble', (tester) async {
      await pump(tester, [
        msg('smth', mid: '9eb5'),
        msg('9eb5:like'),
      ]);
      expect(find.text('smth'), findsOneWidget);
      expect(find.text('9eb5:like'), findsNothing);
    });

    testWidgets('a content-keyed vote is not a bubble', (tester) async {
      await pump(tester, [
        msg('smth', mid: '9eb5'),
        msg('+like:9eb5 1a2b3c4d'),
        msg('+unlike:deadbeef'),
      ]);
      expect(find.text('smth'), findsOneWidget);
      expect(find.textContaining('+like:'), findsNothing);
      expect(find.textContaining('+unlike:'), findsNothing);
    });

    testWidgets('a 64-hex room vote is not a bubble', (tester) async {
      const ev =
          '82ccbaec1f0d4a5b6c7d8e9f00112233445566778899aabbccddeeff00112233';
      await pump(tester, [msg('hello', mid: 'aa11'), msg('$ev:unlike')]);
      expect(find.text('$ev:unlike'), findsNothing);
    });

    testWidgets('an ordinary message that merely looks similar still renders',
        (tester) async {
      await pump(tester, [msg('9eb5:liked it'), msg('zzzz:like')]);
      expect(find.text('9eb5:liked it'), findsOneWidget);
      expect(find.text('zzzz:like'), findsOneWidget);
    });
  });

  group('the heart', () {
    // The vote names the message by id AND by content, because the other
    // device may hold it under a different id or none at all.
    testWidgets('sends a like naming the message by id and content',
        (tester) async {
      await pump(tester, [msg('smth', mid: '9eb5')]);
      await tester.tap(find.byIcon(Icons.favorite_border).first);
      await tester.pump();
      expect(sent, ['+like:9eb5 ${contentKey('smth', '13:33')}']);
    });

    testWidgets('sends an unlike when already liked', (tester) async {
      await pump(tester, [msg('smth', mid: '9eb5', likes: 1, liked: true)]);
      await tester.tap(find.byIcon(Icons.favorite).first);
      await tester.pump();
      expect(sent, ['+unlike:9eb5 ${contentKey('smth', '13:33')}']);
    });

    // Whatever the message, the vote is a fixed handful of bytes — these ride
    // Bluetooth, where quoting the text back would not be free.
    testWidgets('stays small on a long message', (tester) async {
      await pump(tester, [msg('x' * 3000, mid: '9eb5')]);
      await tester.tap(find.byIcon(Icons.favorite_border).first);
      await tester.pump();
      expect(sent.single.length, lessThan(40));
    });

    // A media-only bubble has no content to key on: the id alone has to do.
    testWidgets('falls back to the id alone with no text', (tester) async {
      await pump(tester, [msg('', mid: '9eb5')]);
      await tester.tap(find.byIcon(Icons.favorite_border).first);
      await tester.pump();
      expect(sent, ['+like:9eb5']);
    });

    // Without a mid there is nothing to vote on — offering the heart would
    // send a vote naming nothing.
    testWidgets('is not offered on a message with no id', (tester) async {
      await pump(tester, [msg('smth')]);
      expect(find.byIcon(Icons.favorite_border), findsNothing);
    });

    // Our own bubble shows the tally, never a button: liking yourself is not a
    // thing, and a 0 tally is noise.
    testWidgets('on our own message shows the count and does not vote',
        (tester) async {
      await pump(tester, [
        msg('mine', dir: 'out', mid: 'aa11'),
        msg('mine liked', dir: 'out', mid: 'bb22', likes: 2),
      ]);
      // Nothing at all on the un-liked one, a tally on the other. The heart is
      // FILLED: on our own message it cannot mean "I liked this" (we do not
      // like our own), so it means "this has been liked". It used to draw the
      // hollow outline beside a count of 2, which read as nobody had.
      expect(find.byIcon(Icons.favorite_border), findsNothing);
      expect(find.byIcon(Icons.favorite), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      // Still read-only: tapping our own tally must not cast a vote.
      await tester.tap(find.byIcon(Icons.favorite));
      await tester.pump();
      expect(sent, isEmpty);
    });
  });

  group('replying', () {
    testWidgets('puts the parent id on the wire, not in the text',
        (tester) async {
      await pump(tester, [msg('smth', mid: '9eb5')]);
      await tester.tap(find.text('Reply').first);
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, 'OK');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(sent, ['+9eb5 OK']);
    });

    testWidgets('a plain message carries no marker', (tester) async {
      await pump(tester, [msg('smth', mid: '9eb5')]);
      await tester.enterText(find.byType(TextField).last, 'hello');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(sent, ['hello']);
    });

    testWidgets('quotes the parent it is threaded under', (tester) async {
      await pump(tester, [
        msg('smth', mid: '9eb5'),
        msg('OK', dir: 'out', from: 'X16JK8', mid: 'aa11', parent: '9eb5'),
      ]);
      // The quote shows the parent's text, so the reply reads as an answer.
      expect(find.textContaining('smth'), findsWidgets);
      expect(find.text('OK'), findsOneWidget);
    });
  });

  // Sending rebuilds the thread; the composer used to lose focus with it, so
  // every second message needed a click back into the field.
  testWidgets('the composer keeps focus after sending', (tester) async {
    await pump(tester, [msg('smth', mid: '9eb5')]);
    final field = find.byType(TextField).last;
    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, 'first');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    final node = tester.widget<TextField>(field).focusNode;
    expect(node, isNotNull, reason: 'the composer needs a focus node to keep');
    expect(node!.hasFocus, isTrue);

    // And the field is empty and ready, so the next message needs no click.
    expect(tester.widget<TextField>(field).controller!.text, '');
  });

  // A phone messenger shows nothing until the message is somewhere. There is no
  // server here to take custody, so "pending" is a real and sometimes long
  // state — a tick on a message nobody has received is a lie the user acts on.
  group('delivery ticks', () {
    testWidgets('an unacknowledged message shows no tick at all',
        (tester) async {
      await pump(tester, [msg('on my way', dir: 'out', mid: 'aa11')]);
      expect(find.byIcon(Icons.done), findsNothing);
      expect(find.byIcon(Icons.done_all), findsNothing);
    });

    testWidgets('reaching the other device is a single tick', (tester) async {
      await pump(tester, [
        {...msg('on my way', dir: 'out', mid: 'aa11'), 'status': 'delivered'}
      ]);
      expect(find.byIcon(Icons.done), findsOneWidget);
      expect(find.byIcon(Icons.done_all), findsNothing);
    });

    testWidgets('being read is a double tick', (tester) async {
      await pump(tester, [
        {...msg('on my way', dir: 'out', mid: 'aa11'), 'status': 'read'}
      ]);
      expect(find.byIcon(Icons.done_all), findsOneWidget);
      expect(find.byIcon(Icons.done), findsNothing);
    });

    testWidgets('their messages never carry our ticks', (tester) async {
      await pump(tester, [
        {...msg('hello', mid: 'bb22'), 'status': 'read'}
      ]);
      expect(find.byIcon(Icons.done), findsNothing);
      expect(find.byIcon(Icons.done_all), findsNothing);
    });
  });

  group('the day a message fell on', () {
    // Pinned "now": a Wednesday, so the weekday branch is unambiguous.
    final now = DateTime(2026, 9, 9, 15, 30);

    test('today and yesterday are named, not dated', () {
      expect(chatDayLabel('2026-09-09', now: now), 'Today');
      expect(chatDayLabel('2026-09-08', now: now), 'Yesterday');
    });

    test('the last week reads as a weekday', () {
      expect(chatDayLabel('2026-09-07', now: now), 'Monday');
      expect(chatDayLabel('2026-09-04', now: now), 'Friday');
    });

    test('older this year drops the year; older still keeps it', () {
      expect(chatDayLabel('2026-09-02', now: now), '2 September');
      expect(chatDayLabel('2026-01-31', now: now), '31 January');
      expect(chatDayLabel('2025-12-25', now: now), '25 December 2025');
    });

    test('a time of day never changes the answer', () {
      expect(chatDayLabel('2026-09-09', now: DateTime(2026, 9, 9, 0, 0)), 'Today');
      expect(chatDayLabel('2026-09-09', now: DateTime(2026, 9, 9, 23, 59)), 'Today');
    });

    test('something unparseable is returned as it came, not invented', () {
      expect(chatDayLabel('', now: now), '');
      expect(chatDayLabel('not a date', now: now), 'not a date');
    });
  });

  group('every 1:1 bubble shows its lock', () {
    testWidgets('sealed shows a closed lock, clear text an open one',
        (tester) async {
      await pump(tester, [
        {...msg('sealed words', mid: 'a1'), 'enc': true},
        {...msg('clear words', dir: 'out', mid: 'a2'), 'plain': true},
      ]);
      expect(find.byIcon(Icons.lock), findsOneWidget);
      expect(find.byIcon(Icons.lock_open), findsOneWidget);
    });

    testWidgets('a message with no statement (a group) shows no lock',
        (tester) async {
      await pump(tester, [msg('hello group', mid: 'g1')]);
      expect(find.byIcon(Icons.lock), findsNothing);
      expect(find.byIcon(Icons.lock_open), findsNothing);
    });

    testWidgets('the composer lock follows the conversation, and flips it',
        (tester) async {
      var taps = 0;
      Future<void> withLock(bool on) async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: ChatViewField(
              fieldName: 'chat',
              label: 'Chat',
              fill: true,
              messages: const [],
              onSend: sent.add,
              privacyOn: on,
              onTogglePrivacy: () => taps++,
            ),
          ),
        ));
        await tester.pump();
      }

      await withLock(true);
      expect(find.byIcon(Icons.lock), findsOneWidget);
      await tester.tap(find.byIcon(Icons.lock));
      expect(taps, 1);
      await withLock(false);
      expect(find.byIcon(Icons.lock_open), findsOneWidget);
    });
  });

  group('the composer on a narrow screen', () {
    // A long message used to be squeezed into a column between the attach, lock
    // and send buttons. Past one line the text takes the whole pill and the
    // tools drop to its right-hand corner.
    testWidgets('a long message moves the buttons below, to the right',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatViewField(
            fieldName: 'chat',
            label: 'Chat',
            fill: true,
            messages: const [],
            onSend: sent.add,
            onAttach: () async => null,
            onTogglePrivacy: () {},
          ),
        ),
      ));
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pump();

      final field = find.byType(TextField);
      final send = find.byIcon(Icons.send);

      // One short line: the buttons sit beside the text.
      await tester.enterText(field, 'hi');
      await tester.pump();
      final shortField = tester.getRect(field);
      final shortSend = tester.getRect(send);
      expect(shortSend.left, greaterThan(shortField.right - 1),
          reason: 'beside the field');

      // A long one: the field takes the width and the buttons go underneath.
      await tester.enterText(
          field,
          'this message is long enough that it cannot possibly fit on a '
          'single line of a phone held upright, so it wraps');
      await tester.pump();
      final longField = tester.getRect(field);
      final longSend = tester.getRect(send);
      expect(longSend.top, greaterThanOrEqualTo(longField.bottom - 1),
          reason: 'below the text');
      expect(longSend.right, greaterThan(300), reason: 'at the right edge');
      expect(longField.width, greaterThan(shortField.width),
          reason: 'the text uses the full width');
      expect(find.byIcon(Icons.attach_file), findsOneWidget);
      expect(tester.getRect(find.byIcon(Icons.attach_file)).top,
          greaterThanOrEqualTo(longField.bottom - 1));

      // Back to one line when the text is cleared, and still typing in it.
      await tester.enterText(field, '');
      await tester.pump();
      expect(tester.getRect(send).left,
          greaterThan(tester.getRect(field).right - 1));
    });

    testWidgets('moving the buttons keeps the field focused', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatViewField(
            fieldName: 'chat',
            label: 'Chat',
            fill: true,
            messages: const [],
            onSend: sent.add,
            onAttach: () async => null,
          ),
        ),
      ));
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pump();
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.enterText(
          find.byType(TextField),
          'this message is long enough that it cannot possibly fit on a '
          'single line of a phone held upright, so it wraps');
      await tester.pump();
      final focused = tester
          .widget<EditableText>(find.byType(EditableText))
          .focusNode
          .hasFocus;
      expect(focused, isTrue);
    });
  });

  group('correcting and withdrawing what was said (XPRS.md 7.8)', () {
    Future<void> pumpWith(WidgetTester tester, List<Map<String, dynamic>> messages,
        {bool moderator = false,
        void Function(Map<String, dynamic>, String)? onEdit,
        void Function(Map<String, dynamic>)? onUnsend,
        void Function(Map<String, dynamic>)? onHistory}) async {
      tester.view.physicalSize = const Size(600, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatViewField(
            fieldName: 'chat',
            label: 'Chat',
            fill: true,
            messages: messages,
            onSend: sent.add,
            onEdit: onEdit,
            onUnsend: onUnsend,
            onHistory: onHistory,
            canModerate: moderator,
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('an edited message says edited, a moderated one says by whom',
        (tester) async {
      await pumpWith(tester, [
        {...msg('new wording', mid: 'a1', dir: 'out'), 'edited': true},
        {
          ...msg('[removed]', mid: 'a2', from: 'X1PZ4Q'),
          'edited': true,
          'editedBy': 'X32DVA'
        },
      ]);
      expect(find.text('edited'), findsOneWidget);
      expect(find.text('edited by moderator X32DVA'), findsOneWidget);
    });

    testWidgets('a withdrawn message is a place that says so, with no words',
        (tester) async {
      await pumpWith(tester, [
        {...msg('', mid: 'a1', dir: 'out'), 'deleted': true},
        {...msg('', mid: 'a2', from: 'X1PZ4Q'), 'deleted': true, 'editedBy': 'X32DVA'},
      ]);
      expect(find.text('This message was deleted'), findsOneWidget);
      expect(find.text('Removed by moderator X32DVA'), findsOneWidget);
    });

    testWidgets('our own message offers Edit and Delete for everyone',
        (tester) async {
      await pumpWith(tester, [msg('mine', mid: 'a1', dir: 'out')],
          onEdit: (_, _) {}, onUnsend: (_) {});
      await tester.longPress(find.text('mine'));
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Delete for everyone'), findsOneWidget);
    });

    testWidgets('somebody else\'s is offered nothing, unless we are a moderator',
        (tester) async {
      await pumpWith(tester, [msg('theirs', mid: 'a1')],
          onEdit: (_, _) {}, onUnsend: (_) {});
      await tester.longPress(find.text('theirs'));
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Delete for everyone'), findsNothing);
      await tester.tapAt(const Offset(10, 10)); // close the menu
      await tester.pumpAndSettle();
      await pumpWith(tester, [msg('theirs', mid: 'a1')],
          moderator: true, onEdit: (_, _) {}, onUnsend: (_) {});
      await tester.longPress(find.text('theirs'));
      await tester.pumpAndSettle();
      expect(find.text('Edit as moderator'), findsOneWidget);
      expect(find.text('Remove as moderator'), findsOneWidget);
    });

    testWidgets('Edit puts the words in the composer, and send corrects them',
        (tester) async {
      final calls = <String>[];
      await pumpWith(tester, [msg('meet at six', mid: 'a1', dir: 'out')],
          onEdit: (m, t) => calls.add('${m['mid']}=$t'), onUnsend: (_) {});
      await tester.longPress(find.text('meet at six'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Editing'), findsOneWidget);
      final field = find.byType(TextField);
      expect(tester.widget<TextField>(field).controller!.text, 'meet at six');
      await tester.enterText(field, 'meet at seven');
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      expect(calls, ['a1=meet at seven']);
      expect(sent, isEmpty, reason: 'a correction is not a new message');
      expect(find.textContaining('Editing'), findsNothing);
    });

    testWidgets('sending the words unchanged is not an edit', (tester) async {
      final calls = <String>[];
      await pumpWith(tester, [msg('same', mid: 'a1', dir: 'out')],
          onEdit: (m, t) => calls.add(t), onUnsend: (_) {});
      await tester.longPress(find.text('same'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      expect(calls, isEmpty);
    });

    testWidgets('Delete for everyone asks first, then withdraws', (tester) async {
      final gone = <String>[];
      await pumpWith(tester, [msg('regret', mid: 'a1', dir: 'out')],
          onEdit: (_, _) {}, onUnsend: (m) => gone.add('${m['mid']}'));
      await tester.longPress(find.text('regret'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete for everyone'));
      await tester.pumpAndSettle();
      expect(find.textContaining('cannot be undone'), findsOneWidget);
      expect(gone, isEmpty, reason: 'nothing until it is confirmed');
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(gone, ['a1']);
    });

    testWidgets('Info offers the edit history for an edited message only',
        (tester) async {
      final asked = <String>[];
      await pumpWith(
          tester,
          [
            {...msg('new', mid: 'a1', dir: 'out'), 'edited': true},
            msg('plain', mid: 'a2', dir: 'out'),
          ],
          onEdit: (_, _) {},
          onUnsend: (_) {},
          onHistory: (m) => asked.add('${m['mid']}'));
      await tester.longPress(find.text('new'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Info'));
      await tester.pumpAndSettle();
      expect(find.text('Edit history'), findsOneWidget);
      await tester.tap(find.text('Edit history'));
      await tester.pumpAndSettle();
      expect(asked, ['a1']);
      await tester.longPress(find.text('plain'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Info'));
      await tester.pumpAndSettle();
      expect(find.text('Edit history'), findsNothing);
    });
  });
}
