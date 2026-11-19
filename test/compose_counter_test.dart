// The Status composer counts down to one packet: bytes, not letters, and an
// attachment's token counts too.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/widgets/compose_counter.dart';

void main() {
  test('plain letters cost one each, the edges trimmed', () {
    expect(composeRoomLeft(130, ''), 130);
    expect(composeRoomLeft(130, '  hello  '), 125);
  });

  test('an accented letter costs two and an emoji four', () {
    expect(composeRoomLeft(130, 'ã'), 128);
    expect(composeRoomLeft(130, '😀'), 126);
  });

  test('an attachment token and its space count', () {
    expect(composeRoomLeft(130, 'hi', 'file:abc.jpg'), 130 - 15);
    expect(composeRoomLeft(130, '', 'file:abc.jpg'), 130 - 12);
  });

  test('past the limit the room is negative', () {
    expect(composeRoomLeft(5, 'abcdefg'), -2);
  });

  testWidgets('the number shows, red past the limit', (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: Row(children: [ComposeCounter(-3)]))));
    final t = tester.widget<Text>(find.text('-3'));
    expect(t.style?.color, const Color(0xFFF15C6D));
  });
}
