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
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_mailbox.dart';
import 'package:xprs/services/xprs/xprs_outbox.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_receipt.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
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
    if (s == null || !s.online) {
      dropped++;
      return false;
    }
    s.inbox.add(wire);
    directed++;
    return true;
  }

  void broadcast(String from, String wire) {
    broadcasts++;
    for (final s in stations.values) {
      if (s.call == from || !s.online) continue;
      s.inbox.add(wire);
    }
  }

  bool reachable(String call) {
    final s = stations[call.trim().toUpperCase()];
    return s != null && s.online;
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
    };
    XprsIngest.onReceipt = (p) {
      final r = XprsReceipt.release(p, selfCallsign: s.call);
      if (r == null) return;
      MeshStore.instance.purgeAm(r.id);
      XprsOutbox.instance
          .noteReceipt(r.id, state: r.state, peer: (p['f'] ?? '').toUpperCase());
    };
    XprsIngest.onDirectHeard = (call, bearer) {};

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
