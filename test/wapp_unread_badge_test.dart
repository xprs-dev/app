/// A launcher badge must be a number the user can act on.
///
/// Two authorities write unread for the same wapp — the host's conversation
/// stores under the base key, the wapp's own `unread` message under its intent
/// key — and the tile used to ADD them, so the mail tile read double whenever
/// the mail page was open. The chat wapp sends no `unread` message at all, so
/// reading its intent key alone reported zero forever.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/wapp_unread_service.dart';

void main() {
  final svc = WappUnreadService.instance;

  setUp(() {
    for (final key in svc.counts.value.keys.toList()) {
      final hash = key.indexOf('#');
      if (hash < 0) {
        svc.clearAll(key);
      } else {
        svc.clear(key.substring(0, hash), intent: key.substring(hash + 1));
      }
    }
    expect(svc.counts.value, isEmpty);
  });

  test('two views of the same unread are not added together', () {
    svc.setCount('mail', 3); // the host's conversation stores
    svc.setCount('mail', 3, intent: 'mail'); // the wapp's own tally

    expect(svc.totalFor('mail'), 3,
        reason: 'three messages, counted twice, are still three messages');
  });

  test('genuinely distinct intents still add up', () {
    svc.setCount('x', 2, intent: 'mail');
    svc.setCount('x', 1, intent: 'chat');

    expect(svc.totalFor('x'), 3);
  });

  test('an icon falls back to the wapp total when no intent key exists', () {
    svc.setCount('chat', 4); // only the host wrote anything

    expect(svc.badgeFor('chat', 'chat'), 4,
        reason: 'the chat wapp publishes no intent key; zero would be a lie');
  });

  test('an icon prefers the intent key when the wapp does publish one', () {
    svc.setCount('mail', 9, intent: 'mail');
    svc.setCount('mail', 2);

    expect(svc.badgeFor('mail', 'mail'), 9);
  });
}
