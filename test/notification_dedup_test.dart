/// The same notification, announced twice, is still ONE notification.
///
/// The social inbox is answered out of SQLite, so every app start replays the
/// stored reactions through the announce path. Without a durable identity for a
/// notification, each replay minted a new card and re-lit the bell — which is
/// exactly the "always a 1, always the same notification" the user saw.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/announced_tags_store.dart';
import 'package:xprs/services/notification_service.dart';

void main() {
  setUp(() {
    NotificationService.instance.reset();
    AnnouncedTagsStore.instance.reset();
    // No profile storage in tests: mark the guard loaded-empty so show()
    // consults it instead of buffering until a load that never happens.
    AnnouncedTagsStore.instance.markLoadedForTest();
  });

  test('a tagged notification is shown once, however many times it is raised',
      () {
    final n = XprsNotification(
      level: NotificationLevel.info,
      title: 'someone liked your post',
      source: 'wapp:social',
      tag: 'nostr:abc123',
    );

    NotificationService.instance.show(n);
    NotificationService.instance.show(n); // a replay after a restart
    NotificationService.instance.show(n);

    expect(NotificationService.instance.history, hasLength(1),
        reason: 'the event id IS the identity; the same event is one card');
  });

  test('different events still get their own card', () {
    NotificationService.instance.show(XprsNotification(
      level: NotificationLevel.info,
      title: 'A liked your post',
      source: 'wapp:social',
      tag: 'nostr:aaa',
    ));
    NotificationService.instance.show(XprsNotification(
      level: NotificationLevel.info,
      title: 'B replied to you',
      source: 'wapp:social',
      tag: 'nostr:bbb',
    ));

    expect(NotificationService.instance.history, hasLength(2));
  });

  test('the guard is persistent: a service restart does not re-announce', () {
    final n = XprsNotification(
      level: NotificationLevel.info,
      title: 'someone liked your post',
      source: 'wapp:social',
      tag: 'nostr:restart',
    );
    NotificationService.instance.show(n);
    expect(NotificationService.instance.history, hasLength(1));

    // "Restart": the service loses its memory, the announced store does not
    // (at runtime it reloads notifications/announced.txt from the profile).
    NotificationService.instance.reset();
    NotificationService.instance.show(n);
    expect(NotificationService.instance.history, isEmpty,
        reason: 'the persisted tag set outlives the process');
  });

  test('tagged notifications buffer until the guard has loaded', () {
    AnnouncedTagsStore.instance.reset(); // loaded = false again
    final n = XprsNotification(
      level: NotificationLevel.info,
      title: 'early bird',
      source: 'wapp:social',
      tag: 'nostr:early',
    );
    NotificationService.instance.show(n);
    expect(NotificationService.instance.history, isEmpty,
        reason: 'guard not loaded: nothing may announce yet');
  });

  test('untagged notifications are untouched — no accidental suppression', () {
    for (var i = 0; i < 3; i++) {
      NotificationService.instance.show(XprsNotification(
        level: NotificationLevel.info,
        title: 'build finished',
        source: 'host:updates',
      ));
    }
    expect(NotificationService.instance.history, hasLength(3));
  });

  test('show() reports whether the user was actually told', () {
    final n = XprsNotification(
      level: NotificationLevel.info,
      title: 'someone liked your post',
      source: 'wapp:social',
      tag: 'nostr:told-once',
    );

    // Anything mirroring a notification elsewhere -- a launcher badge -- has
    // to know the difference. Bumping a badge for a suppressed replay is how
    // a tile shows a 1 for news the user read weeks ago.
    expect(NotificationService.instance.show(n), isTrue);
    expect(NotificationService.instance.show(n), isFalse);
  });

  test('a buffered notification does not claim to have been shown', () {
    AnnouncedTagsStore.instance.reset(); // guard not loaded: show() buffers
    final n = XprsNotification(
      level: NotificationLevel.info,
      title: 'waiting for the guard',
      source: 'wapp:social',
      tag: 'nostr:buffered',
    );

    expect(NotificationService.instance.show(n), isFalse);
    expect(NotificationService.instance.history, isEmpty);
  });

  test('an untagged notification always announces', () {
    XprsNotification fresh() => XprsNotification(
          level: NotificationLevel.error,
          title: 'transient status',
          source: 'host:tasks',
        );

    expect(NotificationService.instance.show(fresh()), isTrue);
    expect(NotificationService.instance.show(fresh()), isTrue);
    expect(NotificationService.instance.show(fresh()), isTrue);
  });
}
