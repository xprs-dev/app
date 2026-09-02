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
import 'package:xprs/services/xprs/xprs_packet.dart';
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
    bus.subscribe('chat', rxTopicFor('message'));
    // `nosy` subscribes to something else entirely.
    bus.subscribe('nosy', rxTopicFor('status'));

    final n = WappDelivery.instance
        .deliverMessage(from: 'X1QZ3N', content: 'hello');

    expect(n, 1, reason: 'exactly one engine asked for this topic');
    expect(bus.queueDepth('chat'), 1);
    expect(bus.queueDepth('nosy'), 0,
        reason: 'a wapp that did not subscribe is not told');

    final ev = bus.recv('chat')!;
    expect(ev.topic, rxTopicFor('message'));
    expect(jsonDecode(ev.data)['content'], 'hello');
  });

  test('a packet is published on its own type, with its provenance', () {
    // XPRS.md 4.2 gives thirty types; the bus uses them directly rather than
    // inventing coarse buckets a wapp would have to filter again.
    bus.registerEngine('feed');
    bus.subscribe('feed', rxTopicFor('status'));
    bus.registerEngine('chat');
    bus.subscribe('chat', rxTopicFor('message'));

    final p = XprsPacket.parse(
        't:status f:X1QZ3N ts:2026-09-02_10:00:00 link:ble m:on the hill')!;
    WappDelivery.instance
        .deliverPacket(p, bearer: 'ble', rssi: -61, forUs: false);

    expect(bus.queueDepth('chat'), 0, reason: 'a status is not a message');
    final row = jsonDecode(bus.recv('feed')!.data) as Map<String, dynamic>;
    expect(row['type'], 'status');
    expect(row['from'], 'X1QZ3N');
    // Provenance a wapp legitimately needs: who, how it reached us, how far.
    expect(row['bearer'], 'ble');
    expect(row['rssi'], -61);
    expect(row['link'], 'ble');
    expect(row['id'], isNotEmpty, reason: 'section 5 identifier, for dedup');
    // Every field, in order, so a wapp can read a type the core never parsed.
    expect(row['fields'], contains(equals(['m', 'on the hill'])));
  });

  test('an unknown type is published under its own name, not dropped', () {
    // 4.2: "An unknown type is ignored. It is never an error." A wapp written
    // for a type this build has never heard of works the day a peer sends it.
    bus.registerEngine('future');
    bus.subscribe('future', rxTopicFor('telemetry'));
    final p = XprsPacket.parse('t:telemetry f:X1QZ3N ts:2026-09-02_10:00:00 m:9')!;
    WappDelivery.instance
        .deliverPacket(p, bearer: 'lan', forUs: false);
    expect(bus.queueDepth('future'), 1);
  });

  test('a delivery nobody asked for is counted, not silently dropped', () {
    bus.registerEngine('chat'); // registered, but subscribed to nothing
    final n = WappDelivery.instance
        .deliverMessage(from: 'X1QZ3N', content: 'hello');
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
    bus.subscribe('chat', rxTopicFor('message'));
    bus.setWaker('chat', () => woken++);

    WappDelivery.instance.deliverMessage(from: 'X1A', content: 'a');
    WappDelivery.instance.deliverMessage(from: 'X1A', content: 'b');

    expect(woken, 2);
    expect(bus.queueDepth('chat'), 2);
  });

  test('a non-subscriber is not woken either', () {
    var woken = 0;
    bus.registerEngine('idle');
    bus.setWaker('idle', () => woken++);
    WappDelivery.instance.deliverMessage(from: 'X1A', content: 'a');
    expect(woken, 0, reason: 'waking a wapp that wanted nothing is the drain');
  });
}
