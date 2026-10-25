// A room is drawn in the order things were said, whatever order they got
// here. An archive replays newest first (XPRS.md 11.2.1), so a catch-up's
// rows arrive backwards; the phone at home drew the fetched week upside
// down because every arrival went to the bottom. A bubble that states its
// time is placed by it; one that does not is appended, as before.
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/conversation_store.dart';

void main() {
  late ConversationStore store;
  setUp(() => store = ConversationStore());

  List<String> texts() =>
      [for (final m in store.items['#LOCAL']!.messages) m['text'] as String];

  void arrive(String text, {int? ts, String? mid}) => store.addMessage({
        'id': '#LOCAL',
        'dir': 'in',
        'from': 'MT1',
        'text': text,
        'mid': mid ?? text,
        'time': '10:00',
        if (ts != null) 'ts': ts,
      });

  test('a replay arriving newest first is drawn oldest first', () {
    arrive('third', ts: 1700000300);
    arrive('second', ts: 1700000200);
    arrive('first', ts: 1700000100);
    expect(texts(), ['first', 'second', 'third']);
  });

  test('a live message lands last, and a tie keeps arrival order', () {
    arrive('a', ts: 1700000100);
    arrive('b', ts: 1700000200);
    arrive('c', ts: 1700000200);
    arrive('d', ts: 1700000900);
    expect(texts(), ['a', 'b', 'c', 'd']);
  });

  test('a bubble with no time is appended, and nothing moves past it', () {
    arrive('old', ts: 1700000100);
    arrive('now');
    arrive('older still', ts: 1700000000);
    expect(texts(), ['old', 'now', 'older still'],
        reason: 'the walk back stops at a row that states no time');
  });
}
