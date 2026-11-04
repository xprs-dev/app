// The core says what a notification is about (`core:nostr`); which wapp shows
// it is this app's decision (lib/boot/core_host_app.dart). The core used to
// raise them as `wapp:social` itself (audit 2026-11-04).
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/boot/core_host_app.dart';
import 'package:xprs_core/src/services/notifications/notification.dart';

XprsNotification _n(String source) => XprsNotification(
      level: NotificationLevel.info,
      title: 't',
      body: 'b',
      source: source,
      tag: 'tag',
      scope: NotificationScope.app,
      convo: 'c',
    );

void main() {
  test('a core topic is routed to the wapp that handles it', () {
    final r = routeCoreNotification(_n('core:nostr'));
    expect(r.source, 'wapp:social');
    expect(r.tag, 'tag');
    expect(r.convo, 'c');
    expect(r.body, 'b');
    expect(routeCoreNotification(_n('core:archiver')).source, 'wapp:archiver');
  });

  test('anything else passes through untouched', () {
    final n = _n('wapp:chat');
    expect(identical(routeCoreNotification(n), n), isTrue);
    expect(routeCoreNotification(_n('core:unknown')).source, 'core:unknown');
  });
}
