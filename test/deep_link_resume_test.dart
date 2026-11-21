/// A tapped notification's link reaches the app even when Android started a
/// new Activity for it over an engine that was already running (headless from
/// boot, or the old Activity gone): the Activity keeps the link until asked,
/// and the app asks each time it comes to the front, not only at boot.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/deep_link_service.dart';
import 'package:xprs/services/notification_service.dart';
import 'package:xprs/services/notification_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a link that arrives with a later Activity is read on resume',
      () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    // The native side: hands its link over once, then has none.
    String? held;
    var asked = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.xprs.app/links'),
            (call) async {
      if (call.method != 'getInitialLink') return null;
      asked++;
      final l = held;
      held = null;
      return l;
    });

    final store = NotificationStore.instance
      ..reset()
      ..init();
    final n = XprsNotification(
        level: NotificationLevel.info,
        title: 'ready to install',
        source: 'host:updates');
    await store.record(n);
    final id = NotificationService.idOf(n);

    // Boot: no Activity link yet.
    await DeepLinkService.instance.start();
    expect(asked, 1);
    expect(store.items.value.firstWhere((r) => r.id == id).seen, isFalse);

    // The person taps the notification: a new Activity holds the link, and
    // the app comes to the front.
    held = 'xprs://open?wapp=host%3Aupdates&n=${Uri.encodeQueryComponent(id)}';
    WidgetsBinding.instance
        .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(asked, 2);
    expect(store.items.value.firstWhere((r) => r.id == id).seen, isTrue,
        reason: 'the tapped notification is read');
  });
}
