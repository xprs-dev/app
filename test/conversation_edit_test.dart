// XPRS.md 7.8: a message already drawn is corrected, withdrawn or moderated.
// The wapp states what it shows now; the store replaces the words, the lock and
// the ticks, and keeps whether it was edited and by whom.
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/conversation_store.dart';

void main() {
  late ConversationStore store;

  setUp(() {
    store = ConversationStore();
    store.addMessage({
      'id': 'X1PEER',
      'dir': 'out',
      'from': 'X1ARKL',
      'text': 'meet at six',
      'mid': 'aaa111',
      'time': '09:12',
      'rid': 'aaa111',
      'status': 'delivered',
      'enc': true,
    });
  });

  Map<String, dynamic> msg() => store.items['X1PEER']!.messages.single;

  test('a correction replaces the words and marks it edited', () {
    store.edit({
      'id': 'X1PEER',
      'mid': 'aaa111',
      'text': 'meet at seven',
      'edited': true,
      'enc': true,
      'rid': 'bbb222',
      'status': 'sent',
    });
    expect(msg()['text'], 'meet at seven');
    expect(msg()['edited'], true);
    expect(msg()['enc'], true);
    expect(msg()['rid'], 'bbb222', reason: 'the ticks follow the newest version');
    expect(msg()['status'], 'sent');
  });

  test('an edit that went out in clear text swaps the lock', () {
    store.edit({
      'id': 'X1PEER',
      'mid': 'aaa111',
      'text': 'meet at seven',
      'edited': true,
      'plain': true,
    });
    expect(msg().containsKey('enc'), isFalse);
    expect(msg()['plain'], true);
  });

  test('a moderator\'s edit says who', () {
    store.edit({
      'id': 'X1PEER',
      'mid': 'aaa111',
      'text': '[removed]',
      'edited': true,
      'by': 'X32DVA',
    });
    expect(msg()['editedBy'], 'X32DVA');
    // Voided: the wapp states the original again, and the marks go.
    store.edit({'id': 'X1PEER', 'mid': 'aaa111', 'text': 'meet at six', 'enc': true});
    expect(msg()['text'], 'meet at six');
    expect(msg().containsKey('edited'), isFalse);
    expect(msg().containsKey('editedBy'), isFalse);
  });

  test('a withdrawal keeps the place and loses the words', () {
    store.edit({'id': 'X1PEER', 'mid': 'aaa111', 'text': '', 'deleted': true});
    expect(msg()['deleted'], true);
    expect(msg()['text'], '');
  });

  test('a message drawn already corrected carries the marks', () {
    store.addMessage({
      'id': 'X1PEER',
      'dir': 'in',
      'from': 'X1PEER',
      'text': 'new words',
      'mid': 'ccc333',
      'time': '10:00',
      'edited': true,
      'by': 'X32DVA',
    });
    final m = store.items['X1PEER']!.messages.last;
    expect(m['edited'], true);
    expect(m['editedBy'], 'X32DVA');
  });

  test('an edit for a message that is not here changes nothing', () {
    store.edit({'id': 'X1PEER', 'mid': 'zzz999', 'text': 'x', 'edited': true});
    store.edit({'id': 'nobody', 'mid': 'aaa111', 'text': 'x'});
    expect(msg()['text'], 'meet at six');
  });

  test('the row says whether we hold authority, restated every time', () {
    store.upsert({'id': 'X5GRPA', 'title': 'grp', 'mod': true});
    expect(store.items['X5GRPA']!.mod, isTrue);
    store.upsert({'id': 'X5GRPA', 'title': 'grp'});
    expect(store.items['X5GRPA']!.mod, isFalse);
  });
}
