/// One rule for when a notification has been seen, the same for every wapp:
/// once the person has been shown what it is about. The conversation it names,
/// the view it names, or, naming neither, its wapp. Seen means it leaves the OS
/// shade and the bell, and a new one about what is already on screen is not
/// raised at all.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/notification_service.dart';
import 'package:xprs/services/notification_store.dart';

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
      NotificationStore.instance.init();
      // init loads the profile's history (none in a test) asynchronously; let
      // it land before recording, or it replaces what was recorded.
      await Future<void>.delayed(const Duration(milliseconds: 50));
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
