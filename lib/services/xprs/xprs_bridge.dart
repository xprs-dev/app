/*
 * xprs_bridge — what this station does with a packet meant for somebody else.
 *
 * The firmware has had this since it had bearers, in `bridge_out`
 * (firmware/common/xprs_app/xprs_app.c). It knows which medium a packet
 * arrived on, offers it to every OTHER medium, and repeats it on the one it
 * came from:
 *
 *     if (from != FROM_LAN  && igate)  xprslan_offer(...);
 *     if (from != FROM_BLE  && bridge) xprsble_offer(...);
 *     ...
 *     if (from == FROM_BLE  && digi_ble_on) xprsble_digipeat(...);
 *
 * The phone had half of one of those. `XprsDigipeater.heard` took no bearer at
 * all, so the only thing it could do was air on a single hardcoded lane
 * (`if (b.name != 'ble5') continue;`) — meaning a packet heard on the LAN was
 * repeated onto Bluetooth and never back onto the LAN, and a packet heard on
 * Bluetooth never reached the LAN. An unlabelled gateway in one direction and
 * a wall in the other. This file is the missing half.
 *
 * ── Two different jobs, deliberately not one ─────────────────────────────
 *
 * DIGIPEAT (§13.1) puts a packet back on the medium it came from, for stations
 * past the sender's reach but inside ours. It is jittered and cancellable
 * (§13.2.1) because everyone in earshot heard the same packet at the same
 * moment. That is [XprsDigipeater]'s.
 *
 * BRIDGE carries it to a medium it has not been on. No jitter and no cancel:
 * nobody else on THIS side heard it, so there is nothing to collide with and
 * nothing to stand down for. That is this file's.
 *
 * ── What stops it being a flood ──────────────────────────────────────────
 *
 * The same four rules the digipeater rests on, checked in the same routine
 * ([relayable] — MeshService._relayable): the §13.1 hop budget, §13.2's loop
 * check, §13.2.2's named-relay list, and the `via:` append that makes this
 * station visible as a hop. A bridge is a relay and pays a relay's price.
 *
 * Plus two the bridge alone needs:
 *
 *   §13.11.1  a `local` packet never leaves the short-range bearers. BLE and
 *             the LAN are both short-range, so local traffic crosses between
 *             them; it never reaches Reticulum.
 *   §13.11.3  a packet off the internet is not blindly repeated onto a radio.
 *             That one is enforced by not calling this at all from the
 *             Reticulum lane — see PacketGateway.receiveInternet.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../log_service.dart';
import '../preferences_service.dart';
import '../reticulum/rns_service.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_vocab.dart';

/// Where a packet may be carried, from where it was heard.
class XprsBridgePolicy {
  const XprsBridgePolicy({
    this.bridge = true,
    this.archivers = true,
  });

  /// Carry between the short-range bearers — Bluetooth and the LAN.
  ///
  /// On by default on a phone, and the reason is not politeness: a phone is
  /// already listening on both to know who is around, so the packet is in
  /// memory either way and the only cost is the airing. A room where one
  /// person's phone is on the WiFi and another's is not is otherwise two
  /// meshes that cannot see each other.
  final bool bridge;

  /// Hand what is not `local` to the archivers this operator chose (§36.3).
  ///
  /// Directed, over Reticulum, to a station the operator named — not a
  /// broadcast, and not a gateway for the whole internet. A `local` packet is
  /// never offered: §13.11.1 says it does not leave the bearers in range, and
  /// an archiver is not in range of anything.
  final bool archivers;
}

class XprsBridge {
  XprsBridge._();
  static final XprsBridge instance = XprsBridge._();

  /// The §13.1/§13.2 decision plus the `via:` append. The same routine the
  /// digipeater and the §36.8.1 custody release use: one rule, one place.
  String? Function(String wire)? relayable;

  /// Put [wire] on [bearer]. Returns false when that lane refused it.
  Future<bool> Function(String wire, String bearer)? air;

  /// The short-range bearers this device can actually transmit on, in the
  /// vocabulary [XprsMonitor] uses. LoRa is not here because no phone has the
  /// radio; Reticulum is not here because it is not short-range.
  static const List<String> shortRange = ['ble', 'lan'];

  XprsBridgePolicy policy = const XprsBridgePolicy();

  static int bridged = 0;
  static int toArchivers = 0;

  /// §13 said no: the hop budget is spent, we are already in `via:`, or the
  /// sender named its relays and we are not one.
  static int refusedByRule = 0;

  /// The target lane would not take it — on a phone with WiFi off, every
  /// BLE→LAN attempt lands here. Counted apart from [refusedByRule] because
  /// they are different faults: one is the specification working, the other is
  /// a radio that is not there. The bench had 5 of these and no way to tell
  /// which, which is why they are two numbers.
  static int laneUnavailable = 0;

  static int skippedLocal = 0;

  /// Identifiers already carried, per target lane, so a packet heard twice is
  /// bridged once. Bounded — a busy room must not turn this into a leak.
  final Map<String, int> _sent = {};
  static const int maxSent = 256;

  Map<String, dynamic> get json => {
        'bridged': bridged,
        'toArchivers': toArchivers,
        'refusedByRule': refusedByRule,
        'laneUnavailable': laneUnavailable,
        'skippedLocal': skippedLocal,
        'policy': {'bridge': policy.bridge, 'archivers': policy.archivers},
      };

  /// A packet arrived on [bearer]. Carry it to the lanes it has not been on.
  ///
  /// Repeating it on [bearer] itself is NOT done here — that is §13.1's
  /// digipeat, with its own jitter and cancel, and it runs alongside this.
  void heard(XprsPacket p, String wire, String bearer) {
    final relay = relayable;
    final send = air;
    if (relay == null || send == null || bearer.isEmpty) return;

    final id = xprsIdentifier(p);
    if (id.isEmpty) return;

    // §13.11.1: `local` names the bearers in range, not a distance. It may
    // cross between short-range lanes and must never reach the internet.
    final local = xprsScope(p).scope == XprsScope.local;

    // The §13 decision, once, for every lane this packet might take. A wire
    // that may not be relayed at all is not bridged either.
    final out = relay(wire);
    if (out == null) {
      refusedByRule++;
      return;
    }

    if (policy.bridge) {
      for (final target in shortRange) {
        if (target == _lane(bearer)) continue; // digipeat's job, not ours
        final key = '$target|$id';
        if (_sent.containsKey(key)) continue;
        _remember(key);
        unawaited(_carry(out, target, id, bearer));
      }
    }

    if (local) {
      skippedLocal++;
      return;
    }
    if (policy.archivers) unawaited(_toArchivers(out, id));
  }

  /// The monitor's bearer vocabulary: `ble5` and `ble` are one lane.
  static String _lane(String bearer) {
    final b = bearer.trim().toLowerCase();
    return b == 'ble5' ? 'ble' : b;
  }

  Future<void> _carry(
      String wire, String target, String id, String from) async {
    try {
      final ok = await air!(wire, target);
      if (ok) {
        bridged++;
        LogService.instance
            .add('XPRS: bridged $id ${_lane(from)} -> $target');
      } else {
        // The lane is off, down, or refused the frame. Not a §13 decision.
        laneUnavailable++;
      }
    } catch (e) {
      LogService.instance.add('XPRS: bridge to $target failed: $e');
    }
  }

  /// Hand a non-local packet to each archiver the operator named.
  ///
  /// Directed over Reticulum, the way [XprsForwarder] hands over held mail: a
  /// named station's LXMF destination, not a broadcast. An archiver we cannot
  /// name is skipped rather than shouted at.
  Future<void> _toArchivers(String wire, String id) async {
    final supers =
        PreferencesService.instanceSync?.xprsSuperArchivers ?? const <String>[];
    if (supers.isEmpty) return;
    final parsed = XprsPacket.parse(wire);
    if (parsed == null) return;
    final via = xprsVia(parsed).map((c) => c.trim().toUpperCase()).toSet();
    for (final sa in supers) {
      final call = sa.trim().toUpperCase();
      if (call.isEmpty) continue;
      // It came through them already, so sending it back is a loop (§13.2).
      if (via.contains(call)) continue;
      final key = 'archiver:$call|$id';
      if (_sent.containsKey(key)) continue;
      final hex = RnsService.instance.lxmfDestForCallsign(call);
      if (hex.isEmpty) continue; // not addressable right now; not an error
      _remember(key);
      try {
        final ok = await RnsService.instance
            .wappSendTo('xprs', hex, Uint8List.fromList(utf8.encode(wire)));
        if (ok) {
          toArchivers++;
          LogService.instance.add('XPRS: $id offered to archiver $call (36.3)');
        }
      } catch (e) {
        LogService.instance.add('XPRS: archiver $call refused $id: $e');
      }
    }
  }

  void _remember(String key) {
    if (_sent.length >= maxSent) _sent.remove(_sent.keys.first);
    _sent[key] = DateTime.now().millisecondsSinceEpoch;
  }

  static void debugReset() {
    bridged = 0;
    toArchivers = 0;
    refusedByRule = 0;
    laneUnavailable = 0;
    skippedLocal = 0;
    instance._sent.clear();
    instance.policy = const XprsBridgePolicy();
  }
}
