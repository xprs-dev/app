/// One rule for when a notification has been seen, the same for every wapp:
/// once the person has been shown what it is about. The conversation it names,
/// the view it names, or, naming neither, its wapp. Seen means it leaves the OS
/// shade and the bell, and a new one about what is already on screen is not
/// raised at all.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/notification_service.dart';
import 'package:xprs/services/notification_store.dart';
import 'package:xprs/wapp/wapp_open.dart';

XprsNotification _n(String source,
        {String? convo, String? view, String? tag}) =>
    XprsNotification(
      level: NotificationLevel.info,
      title: 'something happened',
      source: source,
      convo: convo,
      view: view,
      tag: tag,
    );

/// The store keeps its history on disk between runs, and a tag is a row's
/// identity: tags must be new on every run or an old run's row answers.
final String _run = '${DateTime.now().microsecondsSinceEpoch}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('what a notification is about', () {
    bool about(XprsNotification n, String source,
            {String? convo, String? view}) =>
        NotificationService.isAbout(
            nSource: n.source,
            nConvo: n.convo,
            nView: n.view,
            source: source,
            convo: convo,
            view: view);

    test('a conversation is seen when that conversation is shown', () {
      final n = _n('wapp:chat', convo: 'X16JK8');
      expect(about(n, 'wapp:chat', convo: 'X16JK8'), isTrue);
      expect(about(n, 'wapp:chat', convo: '#LOCAL'), isFalse);
      expect(about(n, 'wapp:chat'), isFalse, reason: 'the list is not it');
      expect(about(n, 'wapp:mail', convo: 'X16JK8'), isFalse,
          reason: 'another wapp showing the same id is not it');
    });

    test('a view is seen when that view is shown', () {
      final n = _n('wapp:social', view: 'post:abc');
      expect(about(n, 'wapp:social', view: 'post:abc'), isTrue);
      expect(about(n, 'wapp:social', view: 'post:def'), isFalse);
      expect(about(n, 'wapp:social'), isFalse);
    });

    test('one naming nothing is seen when its wapp is shown at all', () {
      final n = _n('wapp:things');
      expect(about(n, 'wapp:things'), isTrue);
      expect(about(n, 'wapp:things', convo: 'X4DR7K'), isTrue);
      expect(about(n, 'wapp:chat'), isFalse);
    });
  });

  group('seen leaves the bell', () {
    setUp(() async {
      NotificationStore.instance.reset();
      // record() waits for init's history load itself (a fixed delay here
      // lost to it under a loaded full-suite run).
      NotificationStore.instance.init();
    });

    test('marking a view seen marks exactly its rows', () async {
      final store = NotificationStore.instance;
      await store.record(_n('wapp:social', view: 'post:a', tag: '$_run-t1'));
      await store.record(_n('wapp:social', view: 'post:b', tag: '$_run-t2'));
      await store.record(_n('wapp:things', tag: '$_run-t3'));

      NotificationService.instance.markSeen('wapp:social', view: 'post:a');
      await Future<void>.delayed(Duration.zero);
      final seen = {
        for (final r in store.items.value) r.id: r.seen,
      };
      expect(seen['$_run-t1'], isTrue);
      expect(seen['$_run-t2'], isFalse);
      expect(seen['$_run-t3'], isFalse);
    });

    test("a wapp's own notifications panel is all of them", () async {
      final store = NotificationStore.instance;
      await store.record(_n('wapp:social', view: 'post:a', tag: '$_run-u1'));
      await store.record(_n('wapp:social', view: 'post:b', tag: '$_run-u2'));
      await store.record(_n('wapp:things', tag: '$_run-u3'));
      NotificationService.instance.markSeen('wapp:social', all: true);
      await Future<void>.delayed(Duration.zero);
      final seen = {for (final r in store.items.value) r.id: r.seen};
      expect(seen['$_run-u1'], isTrue);
      expect(seen['$_run-u2'], isTrue);
      expect(seen['$_run-u3'], isFalse, reason: "Things' is not Status's");
    });

    // The Android shade's tap carries the notification's identity
    // (xprs://open?...&n=<id>) and every tap door hands it to
    // openNotificationTarget, which marks exactly that one read.
    test('a tapped notification is read, and only that one', () async {
      final store = NotificationStore.instance;
      final tapped = _n('host:updates'); // untagged: identity is its instant
      await store.record(tapped);
      await store.record(_n('wapp:things', tag: '$_run-o2'));
      // No navigator, as when the target cannot be opened: still read.
      await openNotificationTarget('host:updates',
          notificationId: NotificationService.idOf(tapped), navigator: null);
      await Future<void>.delayed(Duration.zero);
      final seen = {for (final r in store.items.value) r.id: r.seen};
      expect(seen[NotificationService.idOf(tapped)], isTrue);
      expect(seen['$_run-o2'], isFalse);
    });

    test('a tap that arrives before the history has loaded still counts',
        () async {
      final store = NotificationStore.instance;
      await store.record(_n('wapp:things', tag: '$_run-c1'));
      // A cold start: the store is loading while the launch link is handled.
      store.reset();
      store.init();
      NotificationService.instance.markSeenById('$_run-c1');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final row = store.items.value.firstWhere((r) => r.id == '$_run-c1');
      expect(row.seen, isTrue);
    });

    test('a restart remembers which rows were read, and only those',
        () async {
      final store = NotificationStore.instance;
      await store.record(_n('wapp:things', tag: '$_run-p1'));
      await store.record(_n('wapp:things', tag: '$_run-p2'));
      NotificationService.instance.markSeenById('$_run-p2');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      store.reset();
      store.init();
      await store.record(_n('wapp:things', tag: '$_run-p3')); // awaits the load
      final seen = {for (final r in store.items.value) r.id: r.seen};
      expect(seen['$_run-p2'], isTrue);
      expect(seen['$_run-p1'], isFalse,
          reason: 'older than the last thing read is not the same as read');
    });

    test('a wapp resolves its own notification, never another wapp\'s',
        () async {
      final store = NotificationStore.instance;
      await store.record(_n('wapp:things', tag: '$_run-r1'));
      NotificationService.instance
          .markSeenById('$_run-r1', source: 'wapp:chat');
      await Future<void>.delayed(Duration.zero);
      expect(store.items.value.firstWhere((r) => r.id == '$_run-r1').seen,
          isFalse);
      NotificationService.instance
          .markSeenById('$_run-r1', source: 'wapp:things');
      await Future<void>.delayed(Duration.zero);
      expect(store.items.value.firstWhere((r) => r.id == '$_run-r1').seen,
          isTrue);
    });

    testWidgets('a host page on screen reads its notifications',
        (tester) async {
      final store = NotificationStore.instance;
      final update = _n('host:updates');
      await tester.runAsync(() async {
        await store.record(update);
        await store.record(_n('wapp:things', tag: '$_run-h2'));
      });
      await tester.pumpWidget(const NotificationTargetView(
          source: 'host:updates', child: SizedBox()));
      await tester.pump();
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      // By id: the history file holds earlier tests' rows too.
      final seen = {for (final r in store.items.value) r.id: r.seen};
      expect(seen[NotificationService.idOf(update)], isTrue);
      expect(seen['$_run-h2'], isFalse, reason: "Things' is not the updater's");
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('a page over a page', () {
    tearDown(() {
      NotificationService.instance.leftView('wapp:chat');
      NotificationService.instance.leftView('host:updates');
    });

    test('closing the page on top leaves the one under it on screen', () {
      final svc = NotificationService.instance;
      svc.viewing('wapp:chat', convo: 'X16JK8');
      svc.viewing('host:updates');
      expect(svc.show(_n('wapp:chat', convo: 'X16JK8')), isTrue,
          reason: 'covered by the Updates page: news');
      svc.leftView('host:updates');
      expect(svc.show(_n('wapp:chat', convo: 'X16JK8')), isFalse,
          reason: 'the conversation is in front again');
    });
  });

  group('what is on screen is not raised', () {
    tearDown(() => NotificationService.instance.leftView('wapp:chat'));

    test('a message for the open conversation is not a notification', () {
      final svc = NotificationService.instance;
      svc.viewing('wapp:chat', convo: 'X16JK8');
      expect(svc.show(_n('wapp:chat', convo: 'X16JK8')), isFalse);
      expect(svc.show(_n('wapp:chat', convo: '#LOCAL')), isTrue,
          reason: 'another conversation is still news');
      svc.leftView('wapp:chat');
      expect(svc.show(_n('wapp:chat', convo: 'X16JK8')), isTrue,
          reason: 'once the page is gone, it is news again');
    });
  });
}
