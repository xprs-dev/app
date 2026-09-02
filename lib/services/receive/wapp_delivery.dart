/*
 * wapp_delivery — the core hands a wapp a finished message, on the bus.
 *
 * The rule this file exists to make true: a wapp owns no transport. It does
 * not open a socket, read a radio, drain an inbox, or know which bearer
 * carried anything. It subscribes to a topic and is handed content.
 *
 * What it replaces is a set of shared pools that any wapp could read at will:
 * `_lxmfInbox` was one flat list of human correspondence with no recipient
 * test on it -- `_admitToInbox` checks that the content is non-empty and is
 * not an XPRS wire, and nothing else -- exposed through `hal_lxmf_recv` to
 * whoever asked. The decision "this belongs to chat" was made nowhere in the
 * core; chat was simply the only wapp that asked. Every wapp also got every
 * raw BLE frame through `hal_ble_scan_read`, and a route was claimed by
 * importing its symbol, because the engine offers every HAL import to every
 * module and swallows the failure when the module does not declare it.
 *
 * That is survivable while every wapp is ours. It is not survivable the
 * moment somebody else's wapp can be installed, which is the point of doing
 * this now rather than later.
 *
 * ── The shape ────────────────────────────────────────────────────────────
 * The core decides the TOPIC from the packet, publishes once, and the broker
 * fans it out to the engines that subscribed -- and wakes them. A wapp that
 * is not subscribed is not woken and is not told, which is what makes
 * installing a stranger's wapp safe: it can read exactly the topics it asked
 * for, and asking is visible.
 *
 * Waking matters as much as routing. `publish` used to only queue, so a wapp
 * found its event on the next `module_tick` -- which is why the responsive
 * ones declare 500-1000 ms intervals and spend 18.8% of the main isolate
 * (measured) asking whether anything arrived. Arrival now drives the tick.
 */
import 'dart:convert';

import '../../wapp/wapp_event_broker.dart';
import '../log_service.dart';
import '../xprs/xprs_packet.dart';
import '../xprs/xprs_vocab.dart';

/// The topics the core publishes. Named for what the content IS, never for
/// the radio that carried it — a wapp that could tell would be a wapp with a
/// transport opinion.
class RxTopic {
  /// A 1:1 message addressed to this station.
  static const message = 'xprs.message';

  /// A message addressed to a group this station belongs to.
  static const group = 'xprs.group';

  /// Somebody's status/observation heard on the air — the feed material.
  static const status = 'xprs.status';

  /// A delivery or read receipt for something we sent.
  static const receipt = 'xprs.receipt';

  static const all = [message, group, status, receipt];
}

class WappDelivery {
  WappDelivery._();
  static final WappDelivery instance = WappDelivery._();

  static int published = 0;
  static int noSubscriber = 0;

  /// Test seam: the last thing published, without standing up an engine.
  static void Function(String topic, Map<String, dynamic> row)? onPublish;

  /// Hand a finished, human-readable message to whichever wapps asked for
  /// this topic.
  ///
  /// [row] carries content and provenance a PERSON needs — who sent it, when,
  /// whether it was sealed — and deliberately not which bearer carried it
  /// (docs/architecture.md §1: "a wapp is not told which radio carried the
  /// message"). `bearer` is available to the core's own views, not here.
  int deliver(String topic, Map<String, dynamic> row) {
    final data = jsonEncode(row);
    final n = WappEventBroker.instance.publish('core', topic, data);
    published++;
    if (n == 0) {
      noSubscriber++;
      // Not an error, and not silent either: a message nobody subscribed to
      // is exactly the state that used to be invisible, because the wapp
      // pulled and nobody could see it had stopped.
      if (noSubscriber <= 3 || noSubscriber % 50 == 0) {
        LogService.instance
            .add('Delivery: $topic reached no subscriber ($noSubscriber so far)');
      }
    }
    try {
      onPublish?.call(topic, row);
    } catch (_) {}
    return n;
  }

  /// The topic a packet belongs on. The core's decision, made from the
  /// packet, in one place.
  static String topicFor(XprsPacket p, {required bool forUs}) {
    if (p.type == 'receipt') return RxTopic.receipt;
    if (p.type == 'message') {
      return xprsAddressesStation(p['d'] ?? '') && forUs
          ? RxTopic.message
          : RxTopic.group;
    }
    return RxTopic.status;
  }

  static void debugReset() {
    published = 0;
    noSubscriber = 0;
    onPublish = null;
  }
}
