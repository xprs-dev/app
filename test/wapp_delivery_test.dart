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
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/receive/packet_gateway.dart';
import 'package:xprs/services/receive/wapp_delivery.dart';
import 'package:xprs/services/xprs/xprs_archive.dart';
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

  test('a packet reaches a subscriber on EVERY link, Reticulum included', () {
    // Reticulum is how two of our stations talk over the internet: an XPRS
    // wire travels inside an LXMF message and the router hands it to the
    // funnel. For XPRS it is a link like BLE or LAN.
    //
    // It was not treated like one. `receive` published every heard packet on
    // its type topic and `receiveInternet` published nothing, so a wapp
    // subscribed to xprs.message got everything off BLE and LAN and silently
    // missed every message that came over the internet.
    XprsArchive.instance.selfCallsign = 'X1SELF';
    bus.registerEngine('chat');
    bus.subscribe('chat', rxTopicFor('message'));

    const wire = 't:message f:X1QZ3N d:X1RD89 ts:2026-09-02_10:00:00 m:hello';
    final bytes = Uint8List.fromList(utf8.encode(wire));

    PacketGateway.instance
        .receive(bytes, bearer: 'ble', lane: RxLane.advert, rssi: -55);
    PacketGateway.instance
        .receive(bytes, bearer: 'lan', lane: RxLane.advert);
    PacketGateway.instance.receiveInternet('hub', bytes);

    expect(bus.queueDepth('chat'), 3,
        reason: 'one delivery per link, Reticulum included');
    final bearers = <String>[];
    for (var i = 0; i < 3; i++) {
      bearers.add(jsonDecode(bus.recv('chat')!.data)['bearer'] as String);
    }
    expect(bearers, ['ble', 'lan', 'rns'],
        reason: 'and each says which link carried it');
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

  test('the event is queued for the subscriber to read', () {
    // Delivery calls the engine (see WappEventBroker.publish); the queue is
    // what the wapp reads with hal_event_recv once it is in
    // module_handle_event. No engine is registered in this test, so only the
    // queue side is exercised here.
    bus.registerEngine('chat');
    bus.subscribe('chat', rxTopicFor('message'));
    WappDelivery.instance.deliverMessage(from: 'X1A', content: 'a');
    WappDelivery.instance.deliverMessage(from: 'X1A', content: 'b');
    expect(bus.queueDepth('chat'), 2);
    expect(jsonDecode(bus.recv('chat')!.data)['content'], 'a');
  });
}
