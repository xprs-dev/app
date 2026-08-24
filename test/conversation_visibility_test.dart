/// A conversation the user cannot open must not badge.
///
/// The store mints a row whenever a message arrives for an unknown id, so an
/// inbound message alone can create a conversation the wapp never lists and no
/// screen can render. Counting those is how a badge ends up pointing at
/// nothing — the user sees a 1 with nowhere to tap it away.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/wapp/geoui/conversation_store.dart';

void main() {
  test('a thread the wapp never listed does not reach the app badge', () {
    final store = ConversationStore();

    store.addMessage({'id': 'ghost', 'dir': 'in', 'text': 'hello?'});

    expect(store.items['ghost']!.unread, 1,
        reason: 'the row still knows, for its own display');
    expect(store.totalUnread, 0,
        reason: 'nothing app-wide may point at a conversation with no door');
  });

  test('the same thread counts once the wapp lists it', () {
    final store = ConversationStore();

    store.addMessage({'id': 'x', 'dir': 'in', 'text': 'hello?'});
    expect(store.totalUnread, 0);

    store.upsert({'id': 'x', 'title': 'A real conversation'});

    expect(store.totalUnread, 1,
        reason: 'now it is on screen and can be opened');
  });

  test('muted and closed stay out of the app badge', () {
    final store = ConversationStore();
    store.upsert({'id': 'm', 'title': 'muted'});
    store.addMessage({'id': 'm', 'dir': 'in', 'text': 'hi'});
    expect(store.totalUnread, 1);

    store.items['m']!.muted = true;
    expect(store.totalUnread, 0);

    store.items['m']!
      ..muted = false
      ..closed = true;
    expect(store.totalUnread, 0);
  });

  test('a row written before the flag existed still counts', () {
    final legacy = ConversationItem.fromJson({
      'id': 'old',
      'title': 'from a previous build',
      'unread': 2,
    });

    expect(legacy.declared, isTrue,
        reason: 'the upgrade must not hide a conversation already on screen');
  });

  test('a notification for an unopenable conversation is refused', () {
    final store = ConversationStore();
    store.addMessage({'id': 'ghost', 'dir': 'in', 'text': 'hi'});
    store.upsert({'id': 'real', 'title': 'real'});

    expect(store.mayNotifyFor('ghost'), isFalse);
    expect(store.mayNotifyFor('real'), isTrue);
    expect(store.mayNotifyFor('never-heard-of'), isTrue,
        reason: 'the notification may be what creates the conversation');
    expect(store.mayNotifyFor(null), isTrue);
  });
}
