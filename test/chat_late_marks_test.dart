// Words that arrived late (ConversationStore.marks): there is no server, so a
// station can hand over words days after they were said. The room draws them
// where they were said, far up the history, and the view must offer a way to
// them: a button over the list that jumps to the oldest one not yet seen, a
// jump that asks the wapp for the rows down to one it does not hold, and a
// report of each marked bubble once it has been on screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/widgets/chat_view_field.dart';

import 'i18n_english.dart';

Map<String, dynamic> msg(int i) => {
      'dir': 'in',
      'from': 'X1A33T',
      'text': 'line $i',
      'time': '13:33',
      'mid': 'm$i',
      'ts': 1000 + i,
    };

void main() {
  installEnglishForTest();

  late List<List<String>> seen;
  late List<String> around;
  String? jump;

  Widget view(List<Map<String, dynamic>> messages, List<String> marks) =>
      MaterialApp(
        home: Scaffold(
          body: ChatViewField(
            fieldName: 'rooms_chat',
            label: '',
            fill: true,
            messages: messages,
            onSend: (_) {},
            marks: marks,
            takeJump: () {
              final j = jump;
              jump = null;
              return j;
            },
            onMarksSeen: seen.add,
            onAround: around.add,
          ),
        ),
      );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  setUp(() {
    seen = [];
    around = [];
    jump = null;
  });

  final sixty = [for (var i = 0; i < 60; i++) msg(i)];

  testWidgets('a mark up the history gets a button; one at the foot is seen',
      (tester) async {
    tester.view.physicalSize = const Size(420, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(view(sixty, ['m3', 'm59']));
    await settle(tester);
    // The foot is on screen: m59 was read there.
    expect(seen.expand((e) => e), contains('m59'));
    expect(seen.expand((e) => e), isNot(contains('m3')));
    // m3 is far up: the button offers it.
    expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await settle(tester);
    expect(find.text('line 3'), findsOneWidget);
    expect(seen.expand((e) => e), contains('m3'));
    expect(find.byIcon(Icons.arrow_upward), findsNothing);
  });

  testWidgets('a mark the view does not hold asks for the rows down to it',
      (tester) async {
    tester.view.physicalSize = const Size(420, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final tail = sixty.sublist(20);
    await tester.pumpWidget(view(tail, ['m5']));
    await settle(tester);
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pump();
    expect(around, ['m5']);
    // The wapp answers with the rows; the view lands on it by itself.
    await tester.pumpWidget(view(sixty, ['m5']));
    await settle(tester);
    expect(find.text('line 5'), findsOneWidget);
    expect(seen.expand((e) => e), contains('m5'));
  });

  testWidgets('a tapped notification lands on its late words', (tester) async {
    tester.view.physicalSize = const Size(420, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    jump = 'm7';
    await tester.pumpWidget(view(sixty, ['m7']));
    await settle(tester);
    expect(find.text('line 7'), findsOneWidget);
    expect(seen.expand((e) => e), contains('m7'));
  });
}
