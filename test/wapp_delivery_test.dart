/*
 * The core routes; the wapp subscribes. Nothing pulls from a shared pool.
 *
 * What this replaces: `_lxmfInbox` was one flat list of human correspondence
 * with no recipient test on it, handed through `hal_lxmf_recv` to whichever
 * wapp asked. "This belongs to chat" was decided nowhere in the core -- chat
 * was simply the only wapp that called it. Any wapp that added the import
 * would have received every private message on the device and could have
 * raised its own notifications for them, because the engine offers every HAL
 * import to every module and swallows the failure when it is not declared.
 *
 * Fine while every wapp is ours; not fine the moment a stranger's wapp can be
 * installed. So: the core picks a topic, publishes once, and the broker
 * delivers only to engines that asked for it.
 */
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/receive/wapp_delivery.dart';
import 'package:xprs/wapp/wapp_event_broker.dart';

void main() {
  late WappEventBroker bus;

  setUp(() {
    bus = WappEventBroker.instance;
    for (final id in bus.registeredEngines().toList()) {
      bus.unregisterEngine(id);
    }
    WappDelivery.debugReset();
  });

  test('only a subscriber is told, and it is told once', () {
    bus.registerEngine('chat');
    bus.registerEngine('nosy');
    bus.subscribe('chat', RxTopic.message);
    // `nosy` subscribes to something else entirely.
    bus.subscribe('nosy', RxTopic.status);

    final n = WappDelivery.instance
        .deliver(RxTopic.message, {'from': 'X1QZ3N', 'content': 'hello'});

    expect(n, 1, reason: 'exactly one engine asked for this topic');
    expect(bus.queueDepth('chat'), 1);
    expect(bus.queueDepth('nosy'), 0,
        reason: 'a wapp that did not subscribe is not told');

    final ev = bus.recv('chat')!;
    expect(ev.topic, RxTopic.message);
    expect(jsonDecode(ev.data)['content'], 'hello');
  });

  test('the wapp is never told which radio carried it', () {
    bus.registerEngine('chat');
    bus.subscribe('chat', RxTopic.message);
    WappDelivery.instance.deliver(RxTopic.message, {
      'from': 'X1QZ3N',
      'content': 'hello',
      'ts': 123,
    });
    final row = jsonDecode(bus.recv('chat')!.data) as Map<String, dynamic>;
    expect(row.containsKey('via'), isFalse);
    expect(row.containsKey('bearer'), isFalse);
    expect(row.containsKey('rssi'), isFalse);
  });

  test('a delivery nobody asked for is counted, not silently dropped', () {
    bus.registerEngine('chat'); // registered, but subscribed to nothing
    final n = WappDelivery.instance
        .deliver(RxTopic.message, {'from': 'X1QZ3N', 'content': 'hello'});
    expect(n, 0);
    expect(WappDelivery.noSubscriber, 1,
        reason: 'the old pull model made this state invisible');
  });

  test('arrival wakes the engine instead of waiting for its tick', () {
    // The battery point. `publish` used to only queue, so a wapp found the
    // event on its next module_tick -- which is why the responsive ones
    // declare 500-1000ms intervals and spend 18.8% of the main isolate
    // (measured) asking whether anything arrived.
    var woken = 0;
    bus.registerEngine('chat');
    bus.subscribe('chat', RxTopic.message);
    bus.setWaker('chat', () => woken++);

    WappDelivery.instance.deliver(RxTopic.message, {'content': 'a'});
    WappDelivery.instance.deliver(RxTopic.message, {'content': 'b'});

    expect(woken, 2);
    expect(bus.queueDepth('chat'), 2);
  });

  test('a non-subscriber is not woken either', () {
    var woken = 0;
    bus.registerEngine('idle');
    bus.setWaker('idle', () => woken++);
    WappDelivery.instance.deliver(RxTopic.message, {'content': 'a'});
    expect(woken, 0, reason: 'waking a wapp that wanted nothing is the drain');
  });
}
