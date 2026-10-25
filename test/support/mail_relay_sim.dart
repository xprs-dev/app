/*
 * A three-station bench in one process: two people who are never awake at the
 * same moment, and an archiver that is always there.
 *
 * This is the situation the field report describes and the one no unit test
 * could reach, because the failure is not in any single station — every one of
 * them behaves correctly on its own — it is in what they owe each other. So
 * the harness runs the REAL receive funnel (XprsIngest), the REAL custody
 * store (MeshStore), the REAL receipts (XprsReceipt) and the REAL mailbox
 * logic (XprsMailbox) for each station in turn, over a virtual air that drops
 * anything addressed to a station that is offline.
 *
 * Turn-based on purpose: the singletons in this codebase are per-device, so a
 * station's turn re-points them at that station's own databases. What crosses
 * between turns is only what crossed the air.
 */
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:hex/hex.dart';
import 'package:xprs/services/mesh/mesh_store.dart';
import 'package:xprs/services/xprs/xprs_archive.dart';
import 'package:xprs/services/xprs/xprs_forwarder.dart';
import 'package:xprs/services/xprs/xprs_gossip.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_mailbox.dart';
import 'package:xprs/services/xprs/xprs_observation.dart';
import 'package:xprs/services/xprs/xprs_outbox.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_receipt.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/services/xprs/xprs_vocab.dart';
import 'package:xprs/util/nostr_crypto.dart';

BigInt _scalar(String hex) {
  var r = BigInt.zero;
  for (final b in HEX.decode(hex)) {
    r = (r << 8) | BigInt.from(b);
  }
  return r;
}

/// One station on the bench.
class SimStation {
  SimStation(this.call, this.dir)
      : privHex = NostrCrypto.generateKeyPair().privateKeyHex {
    pubHex = NostrCrypto.derivePublicKey(privHex);
  }

  final String call;
  final String dir;
  final String privHex;
  late final String pubHex;

  /// Reachable over the virtual air right now. A station that is offline hears
  /// nothing and can be sent nothing — which is the entire point.
  bool online = true;

  /// On the internet (addressable over the directed lane). A BLE-only pocket
  /// station is `false`: it is reached only by a neighbour it shares a radio
  /// with (see [SimAir.link]), which is the case 12.12 exists for.
  bool internet = true;

  /// What arrived over a RADIO and has not been ingested yet: these go in
  /// through the radio door (XprsIngest.heard), the internet inbox through
  /// the Reticulum one.
  final List<String> radioInbox = [];

  /// This station's chosen archivers (12.3).
  List<String> archivers = [];

  /// What arrived and has not been ingested yet.
  final List<String> inbox = [];

  /// Packets that reached a PERSON here (the wapp door).
  final List<XprsPacket> delivered = [];

  /// Receipts this station composed.
  final List<String> receiptsSent = [];

  BigInt get scalar => _scalar(privHex);
}

/// The air. Directed sends reach a station only when it is online; a broadcast
/// reaches every online station but the sender.
class SimAir {
  SimAir(this.stations);
  final Map<String, SimStation> stations;

  int directed = 0, dropped = 0, broadcasts = 0;

  bool sendTo(String call, String wire) {
    final s = stations[call.trim().toUpperCase()];
    if (s == null || !s.online || !s.internet) {
      dropped++;
      return false;
    }
    s.inbox.add(wire);
    directed++;
    return true;
  }

  /// Radio adjacency: who hears whom over a short-range bearer.
  final Set<String> _radio = {};
  int radioFrames = 0;

  void link(String a, String b) {
    _radio.add('${a.toUpperCase()}|${b.toUpperCase()}');
    _radio.add('${b.toUpperCase()}|${a.toUpperCase()}');
  }

  bool inRadioRange(String a, String b) =>
      _radio.contains('${a.toUpperCase()}|${b.toUpperCase()}');

  /// One frame on the air from [from]: every online station in radio range
  /// hears it, whoever it is addressed to (a radio is a broadcast medium).
  void radio(String from, String wire) {
    radioFrames++;
    for (final s in stations.values) {
      if (s.call == from || !s.online) continue;
      if (inRadioRange(from, s.call)) s.radioInbox.add(wire);
    }
  }

  void broadcast(String from, String wire) {
    broadcasts++;
    for (final s in stations.values) {
      if (s.call == from || !s.online) continue;
      s.inbox.add(wire);
    }
  }

  /// Reachable over the DIRECTED lane: the mailbox's and the forwarder's
  /// question. A BLE-only station is never reachable this way, however
  /// online it is; that is what makes its mail travel by gateway.
  bool reachable(String call) {
    final s = stations[call.trim().toUpperCase()];
    return s != null && s.online && s.internet;
  }
}

/// The bench itself.
class MailRelaySim {
  MailRelaySim._(this.root, this.air, this.stations);

  final Directory root;
  final SimAir air;
  final Map<String, SimStation> stations;

  static MailRelaySim build(List<String> calls) {
    final root = Directory.systemTemp.createTempSync('mail_relay_sim_');
    final map = <String, SimStation>{};
    for (final c in calls) {
      map[c] = SimStation(c, '${root.path}/$c');
    }
    return MailRelaySim._(root, SimAir(map), map);
  }

  SimStation operator [](String call) => stations[call]!;

  void dispose() {
    MeshStore.instance.close();
    XprsArchive.instance.close();
    XprsGossip.instance.close();
    XprsForwarder.instance.debugReset();
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  }

  Uint8List? _keyOf(String call) {
    final s = stations[call.trim().toUpperCase()];
    if (s == null) return null;
    return Uint8List.fromList(HEX.decode(s.pubHex));
  }

  /// Bind every per-device singleton to [s] and run [body] as that station.
  Future<T> as<T>(SimStation s, Future<T> Function() body) async {
    XprsArchive.instance.close();
    MeshStore.instance.close();
    XprsArchive.instance.selfCallsign = s.call;
    XprsArchive.instance.keyResolver = _keyOf;
    XprsArchive.instance.init('${s.dir}/archive.db');
    MeshStore.instance.init('${s.dir}/mesh.db');
    XprsOutbox.debugReset();
    // Each station's own whereabouts table (12.9.4), and the forwarder that
    // routes by it (12.8.1) wired to this bench's lanes. The forwarder's
    // once-per-gateway memory is per DEVICE, so it is reset with the rest of
    // the per-device state when the bench changes hands.
    XprsGossip.instance.close();
    XprsGossip.instance.init('${s.dir}/gossip.db');
    XprsForwarder.instance.debugReset();
    XprsForwarder.instance
      ..sendTo = ((call, wire) async => air.sendTo(call, wire))
      // The device's test (XprsMailbox.reachable): a directed path, or heard
      // directly -- here, sharing a radio with a station that is up.
      ..canDeliver = ((call) =>
          air.reachable(call) ||
          (air.inRadioRange(s.call, call) &&
              (stations[call.toUpperCase()]?.online ?? false)))
      ..holdersOf = ((call) => XprsArchive.instance.holdersFor(call))
      ..namedArchivers = (() => s.archivers)
      ..heldFor = ((call) => MeshStore.instance.heldWiresFor(call));
    XprsGossip.instance.onSighting = (call, gateway) {
      if (gateway == s.call) return;
      forwardRetries.add(call);
      // The device does this unawaited off the funnel; the bench runs it
      // when the scenario asks (retryHeld), so a turn stays deterministic.
    };

    XprsIngest.onDeliver = (p, bearer) => _deliver(s, p);
    XprsIngest.onCarry = (wire, target) {
      final p = XprsPacket.parse(wire);
      if (p == null) return;
      MeshStore.instance.offer(
        target: target,
        sender: (p['f'] ?? '').toUpperCase(),
        wire: Uint8List.fromList(wire.codeUnits),
        am: xprsIdentifier(p),
        inTransit: true,
      );
      // As mesh_service does: park it, then let 12.8.1 move it toward
      // where the recipient actually is. Collected rather than awaited so
      // a drain stays synchronous; [forwardParked] runs them.
      pendingForwards.add((target, wire));
    };
    XprsIngest.onReceipt = (p) {
      final r = XprsReceipt.release(p, selfCallsign: s.call);
      if (r == null) return;
      MeshStore.instance.purgeAm(r.id);
      XprsOutbox.instance
          .noteReceipt(r.id, state: r.state, peer: (p['f'] ?? '').toUpperCase());
    };
    // Our own radio is its own witness (12.9.4): a packet that reached us
    // unrelayed over a radio writes "call is at OUR ear" into our table.
    XprsIngest.onDirectHeard = (call, bearer) =>
        XprsGossip.instance.noteDirect(call, s.call, bearer: bearer);

    XprsMailbox.instance
      ..selfCallsign = (() => s.call)
      ..archivers = (() => s.archivers)
      ..sendTo = ((call, wire) async => air.sendTo(call, wire))
      ..publish = ((wire) async => air.broadcast(s.call, sign(s, wire)))
      ..outboxState = ((id) => XprsOutbox.instance.stateOf(id))
      ..holdersOf = ((call) => XprsArchive.instance.holdersFor(call))
      ..reachable = ((call) => air.reachable(call))
      ..held = (() => [
            for (final target in MeshStore.instance.heldTargets())
              for (final row in MeshStore.instance
                  .releasableFor(target, selfCallsign: s.call))
                HeldMail(
                    key: row.key,
                    target: target,
                    wire: String.fromCharCodes(row.wire)),
          ])
      ..noteAttempt = ((key) => MeshStore.instance.noteReleased(key));

    try {
      return await body();
    } finally {
      XprsIngest.onDeliver = null;
      XprsIngest.onCarry = null;
      XprsIngest.onReceipt = null;
      XprsIngest.onDirectHeard = null;
    }
  }

  /// Sign a wire as [s].
  String sign(SimStation s, String wire) {
    final p = XprsPacket.parse(wire);
    if (p == null) return wire;
    return xprsSign(p, s.scalar).encode();
  }

  /// Ingest everything waiting for [s]. Must be called inside [as].
  void drain(SimStation s) {
    final wires = [...s.inbox];
    s.inbox.clear();
    for (final w in wires) {
      final p = XprsPacket.parse(w);
      if (p == null) continue;
      // The internet door, which is the one an always-on archiver lives
      // behind (XprsIngest.reticulum). The radio door is [XprsIngest.heard]
      // and MeshCustody parks there; both are exercised by the app, and it is
      // the internet one this bench is about.
      XprsIngest.reticulum(
          (p['f'] ?? '').toUpperCase(), Uint8List.fromList(utf8.encode(w)));
    }
    // The radio door: what a neighbour aired. Here the funnel's carry hook
    // parks a third party's mail, and its direct-hearing hook feeds gossip.
    final frames = [...s.radioInbox];
    s.radioInbox.clear();
    for (final w in frames) {
      final p = XprsPacket.parse(w);
      if (p == null) continue;
      XprsIngest.heard(p, bearer: 'ble', selfCallsign: s.call);
      // XprsBridge's archiver half (XprsBridgePolicy.archivers, on by
      // default): a packet heard on a radio is offered to this station's
      // chosen archivers over the directed lane. It is how an archiver on
      // the internet OVERHEARS a receipt aired on somebody's Bluetooth
      // (12.8.3 step 5), and it is one line of the device's policy, not a
      // routing decision of the bench's own.
      if (xprsMayCarry(p)) {
        for (final a in s.archivers) {
          if (a != (p['f'] ?? '').toUpperCase()) air.sendTo(a, w);
        }
      }
    }
  }

  // ── 12.8.1 on the bench ──────────────────────────────────────────────────

  /// (target, wire) pairs the carry hook parked during the last drain, each
  /// awaiting the forwarder. Must be run inside [as], as that station.
  final List<(String, String)> pendingForwards = [];

  /// Callsigns gossip just learned a NEW gateway for (XprsGossip.onSighting).
  final List<String> forwardRetries = [];

  /// Run the forwarder over what the last drain parked. Returns the gateways
  /// each packet went to.
  Future<List<String>> forwardParked(SimStation s) async {
    final out = <String>[];
    final jobs = [...pendingForwards];
    pendingForwards.clear();
    for (final (target, wire) in jobs) {
      out.addAll(await XprsForwarder.instance
          .maybeForward(target, wire, selfBase: s.call));
    }
    return out;
  }

  /// The device's reaction to a new sighting: re-run the forwarder over the
  /// mail held for each callsign gossip just placed somewhere new.
  Future<int> retryHeld(SimStation s) async {
    var moved = 0;
    final calls = {...forwardRetries};
    forwardRetries.clear();
    for (final c in calls) {
      moved += await XprsForwarder.instance.retry(c, selfBase: s.call);
    }
    return moved;
  }

  /// [s] beacons on its radio: the discovery observation every neighbour in
  /// range hears, which is how a gateway learns [s] is at its ear.
  void beacon(SimStation s) {
    final p = xprsComposeObservation(
        self: s.call, link: 'ble', heard: const [], budget: 250,
        signingKey: s.scalar, ts: xprsNowTs());
    if (p != null) air.radio(s.call, p.encode());
  }

  /// [s] tells its archivers who it hears (12.1): the signed observation,
  /// deposited as an addressed copy per archiver -- what
  /// MeshService._reportHeard does on the device.
  int report(SimStation s, {required List<String> heard, String link = 'ble'}) {
    final p = xprsComposeObservation(
        self: s.call, link: link, heard: heard, budget: 250,
        signingKey: s.scalar, ts: xprsNowTs());
    if (p == null) return 0;
    var n = 0;
    for (final a in s.archivers) {
      if (air.sendTo(a, p.encode())) n++;
    }
    return n;
  }

  /// [s] delivers what it holds for [to] over the radio, the way
  /// release-on-hearing does (12.8.1): each held wire re-aired once with
  /// [s] in `via:`. Must be called inside [as] for [s].
  int releaseOnRadio(SimStation s, SimStation to) {
    var n = 0;
    for (final row in MeshStore.instance.releasableFor(to.call,
        selfCallsign: s.call)) {
      final wire = String.fromCharCodes(row.wire);
      final p = XprsPacket.parse(wire);
      if (p == null) continue;
      final carried = xprsAppendVia(p, s.call);
      MeshStore.instance.noteReleased(row.key);
      air.radio(s.call, carried.fits ? carried.encode() : wire);
      n++;
    }
    return n;
  }

  /// A message reached a person here: record it and answer with a receipt —
  /// to the sender, and to everyone holding a copy on the sender's behalf.
  void _deliver(SimStation s, XprsPacket p) {
    s.delivered.add(p);
    // The archive queues admissions and writes them in batches, and a receipt
    // is refused to a station "never exchanged with" (13.7.1) — which the very
    // message being delivered is what makes false. Flushing here is what the
    // 20-second timer does on a device.
    XprsArchive.instance.flush();
    final ack = XprsReceipt.compose(p,
        selfCallsign: s.call, signingKey: s.scalar, state: 'ack');
    if (ack == null) return;
    final signed = ack.encode(); // compose signed it with our key
    s.receiptsSent.add(signed);
    if (!s.internet) {
      // A BLE-only station has one lane: the air. The receipt is mail for
      // the sender, and whoever hears it carries it (12.8.3 step 6).
      air.radio(s.call, signed);
      return;
    }
    air.sendTo((p['f'] ?? '').toUpperCase(), signed);
    for (final holder
        in XprsMailbox.instance.receiptFanout(p, selfBase: s.call)) {
      air.sendTo(holder, signed);
      XprsMailboxCounters.receiptsToHolders++;
    }
  }

  /// Compose, sign and send one directed packet from [s], the way the core
  /// does: try the direct lane, and arm the deposit that outlives us.
  Future<String> send(SimStation s, String wire) async {
    final signed = sign(s, wire);
    final p = XprsPacket.parse(signed)!;
    final id = xprsIdentifier(p);
    final dest = (p['d'] ?? '').toUpperCase();
    XprsOutbox.instance.noteSent(id, dest);
    air.sendTo(dest, signed);
    return signed;
  }

  /// How many packets [s] is holding for other people.
  int heldCount(SimStation s) => MeshStore.instance.countPending();
}
