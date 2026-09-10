/// The bell must not re-light for something the user has already read.
///
/// Wapps re-subscribe and re-ingest their backlog on every start, so the same
/// event is announced again and again across restarts. Unread used to be
/// "timestamp newer than the last time the list was opened" — and a replayed
/// event was re-recorded with a FRESH timestamp, so it jumped back above that
/// line. The row is the same row (the tag is its id), which is why the bell
/// sat on "1", forever, for a notification the user had read many times.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/notification_service.dart';
import 'package:xprs/services/notification_store.dart';

XprsNotification _n(String tag, {String source = 'wapp:chat'}) =>
    XprsNotification(
      level: NotificationLevel.info,
      title: 'a message arrived',
      source: source,
      tag: tag,
    );

void main() {
  _tapTargetSurvives();
  // record()/markAllSeen() write through the profile root, which does not
  // exist here; every write is inside a try/catch, so the in-memory behaviour
  // under test runs unchanged.
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => NotificationStore.instance.reset());

  test('a replayed notification does not re-light a bell that was cleared',
      () async {
    final store = NotificationStore.instance;

    await store.record(_n('mail:abc'));
    expect(store.unreadCount.value, 1);

    await store.markAllSeen();
    expect(store.unreadCount.value, 0);

    // The restart: the wapp replays its backlog and announces the same event
    // again. A new XprsNotification, so a new DateTime.now() inside it.
    await store.record(_n('mail:abc'));

    expect(store.items.value, hasLength(1),
        reason: 'the tag is the identity — one event, one row');
    expect(store.unreadCount.value, 0,
        reason: 'the user already read this one; a replay is not news');
  });

  test('a genuinely new notification still lights the bell', () async {
    final store = NotificationStore.instance;
    await store.record(_n('mail:abc'));
    await store.markAllSeen();

    await store.record(_n('mail:def'));

    expect(store.unreadCount.value, 1);
  });

  test('marking one source read leaves the others unread', () async {
    final store = NotificationStore.instance;
    await store.record(_n('like:1', source: 'wapp:social'));
    await store.record(_n('msg:1', source: 'wapp:chat'));
    expect(store.unreadCount.value, 2);

    await store.markSeenBySource('wapp:social');

    expect(store.unreadCount.value, 1,
        reason: 'reading the social panel says nothing about chat');
    final unread = store.items.value.where((e) => e.seen != true).single;
    expect(unread.source, 'wapp:chat');
  });

  test('a notification arriving while the list is open is seen on close',
      () async {
    final store = NotificationStore.instance;
    await store.markAllSeen(); // the user opens the page

    await store.record(_n('msg:while-open')); // it arrives under their eyes
    expect(store.unreadCount.value, 1);

    await store.markAllSeen(); // the page closes

    expect(store.unreadCount.value, 0);
  });

  test('a row written before the seen flag existed keeps the old behaviour',
      () async {
    final legacy = StoredNotification.fromJson({
      'id': 'old:1',
      'level': 'info',
      'title': 'from a previous build',
      'source': 'wapp:chat',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    expect(legacy.seen, isNull,
        reason: 'absent in the file means unknown, not false');
    expect(legacy.toJson().containsKey('seen'), isFalse);
  });
  test('a chat message does not light the bell (the chat icon owns it)',
      () async {
    final store = NotificationStore.instance;
    // A conversation notification: source wapp + a convo tap target.
    await store.record(XprsNotification(
      level: NotificationLevel.info,
      title: '#LOCAL',
      source: 'wapp:chat',
      convo: '#LOCAL',
      tag: 'chat:#LOCAL:abc',
    ));
    expect(store.unreadCount.value, 0,
        reason: 'chat unread belongs to the chat icon, not the bell');
    expect(store.items.value, isEmpty,
        reason: 'and it is not stacked into the bell panel either');
  });

  test('a non-conversation wapp notification still lights the bell', () async {
    final store = NotificationStore.instance;
    // No convo: an alert with nowhere else to go (an error, a mesh event).
    await store.record(XprsNotification(
      level: NotificationLevel.warning,
      title: 'radio refused the beacon',
      source: 'wapp:mesh',
      tag: 'mesh:beacon:1',
    ));
    expect(store.unreadCount.value, 1);
  });

}

/// A notification's tap target survives being written down.
///
/// Social's target is a THREAD, not a conversation: "X1FRND replied to you"
/// has to open that exchange. The row outlives the app — the user may come
/// back to the bell tomorrow — so the target is persisted with it. Dropping it
/// on the way to disk lands the tap on the feed, and the person is left to go
/// and find what they were told about.
void _tapTargetSurvives() {
  test('the view is stored, reloaded, and kept by copyWith', () {
    final stored = StoredNotification.fromNotification(XprsNotification(
      level: NotificationLevel.info,
      title: 'Social',
      body: 'X1FRND replied to you',
      source: 'wapp:social',
      tag: 'abc123',
      view: 'post:def456',
    ));
    expect(stored.view, 'post:def456');
    expect(stored.copyWith(seen: true).view, 'post:def456');

    final back = StoredNotification.fromJson(stored.toJson());
    expect(back.view, 'post:def456');
    expect(back.id, 'abc123', reason: 'the tag is the row');

    // A row written by an older build has none, and must still load.
    final legacy = StoredNotification.fromJson({
      'id': 'x',
      'level': 'info',
      'title': 'Chat',
      'source': 'wapp:chat',
      'convo': 'X1FRND',
      'timestamp': 1,
    });
    expect(legacy.view, isNull);
    expect(legacy.convo, 'X1FRND');
  });
}
