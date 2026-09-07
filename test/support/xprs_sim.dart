/*
 * xprs_sim — a reusable in-process stress harness for the XPRS federation.
 *
 * Build a constellation of ordinary nodes and large ("always-on") archivers,
 * each node assigned a favourite archiver, then drive the behaviours the spec
 * describes and assert the system properties at scale — no hardware:
 *
 *   - group posts copied to each sender's favourite archiver (§12.12.2);
 *   - files advertised as signed provider records (§12.9.2);
 *   - large archivers finding each other and syncing, via the REAL
 *     ProviderRecord + PointerSync federation (§12.9.4) plus the public-traffic
 *     catch-up (§12.9.3);
 *   - cross-archiver hash resolution (a q:have miss answered from the index).
 *
 * The per-bearer byte middle and the LXMF push are the mocked seams
 * (architecture.md §6); everything that carries the design — signatures,
 * provider records, the sync merge with verify-on-insert — is the real code.
 *
 * [SimKeys] is a standalone secp256k1 signer reusable by any XPRS test that
 * needs signed packets (the eviction test uses it to build declared mail).
 */
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:hex/hex.dart';
import 'package:reticulum/reticulum.dart';
import 'package:reticulum/src/services/files/dht/pointer_log.dart';
import 'package:reticulum/src/services/files/dht/pointer_sync.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/util/nostr_crypto.dart';

String hexOf(List<int> b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
Uint8List sha256Of(List<int> b) =>
    Uint8List.fromList(crypto.sha256.convert(b).bytes);
Uint8List shaBytesOfHex(String h) => Uint8List.fromList([
      for (var i = 0; i < h.length; i += 2)
        int.parse(h.substring(i, i + 2), radix: 16)
    ]);

/// A secp256k1 (nostr) keypair per callsign, plus the resolver the core uses to
/// verify what a callsign signed. Reusable across stress tests.
class SimKeys {
  final _priv = <String, BigInt>{};
  final _pub = <String, Uint8List>{};

  void ensure(String call) {
    _priv.putIfAbsent(call.toUpperCase(), () {
      final kp = NostrCrypto.generateKeyPair();
      var d = BigInt.zero;
      for (final b in HEX.decode(kp.privateKeyHex)) {
        d = (d << 8) | BigInt.from(b);
      }
      _pub[call.toUpperCase()] = Uint8List.fromList(HEX.decode(kp.publicKeyHex));
      return d;
    });
  }

  /// Sign [wire] as [call] and return the encoded, signed wire.
  String sign(String call, String wire) {
    ensure(call);
    return xprsSign(XprsPacket.parse(wire)!, _priv[call.toUpperCase()]!).encode();
  }

  Uint8List? resolve(String call) =>
      _pub[call.split('-').first.toUpperCase()];
}

/// A large, always-on archiver: a group-message spool, a file-location index,
/// and its own signed log of the pointers its favourites deposited.
class LargeArchiver {
  LargeArchiver(this.callsign, this.identity) : log = PointerLog(epoch: callsign);
  final String callsign;
  final RnsIdentity identity;
  final PointerLog log;
  final Map<String, ProviderRecord> index = {}; // synced view (own + peers')
  final Set<String> messages = {}; // group posts held (own + synced)
}

/// One ordinary node: callsign, favourite-archiver index, signing identity.
class SimNode {
  SimNode(this.callsign, this.fav, this.identity);
  final String callsign;
  final int fav;
  final RnsIdentity identity;
}

/// A constellation of [nodes] ordinary stations and [archivers] large ones,
/// each node randomly assigned one favourite archiver.
class Constellation {
  Constellation._(this.larges, this.nodes);
  final List<LargeArchiver> larges;
  final List<SimNode> nodes;

  /// provider-pubkey (hex) → the callsign that holds it, for turning a synced
  /// record back into a holder to name in `m:try`.
  final Map<String, String> pubToCall = {};

  static Future<Constellation> build(
      {required int nodes, int archivers = 3, int seed = 1234}) async {
    final rng = Random(seed);
    final larges = <LargeArchiver>[];
    for (var k = 0; k < archivers; k++) {
      larges.add(LargeArchiver('X3ARC$k', await RnsIdentity.generate()));
    }
    final list = <SimNode>[];
    for (var i = 0; i < nodes; i++) {
      list.add(SimNode('X1N${i.toString().padLeft(2, '0')}',
          rng.nextInt(archivers), await RnsIdentity.generate()));
    }
    return Constellation._(larges, list);
  }

  int get nArch => larges.length;

  /// How many nodes favour archiver [k].
  int favourites(int k) => nodes.where((n) => n.fav == k).length;

  /// Every node posts [each] group messages; §12.12.2 pushes a copy of each to
  /// the sender's favourite archiver. Returns the total posts sent.
  int postGroup(int each) {
    for (final n in nodes) {
      for (var m = 0; m < each; m++) {
        larges[n.fav].messages.add('${n.callsign}#$m');
      }
    }
    return nodes.length * each;
  }

  /// Each node hosts one file (a deterministic synthetic hash), advertised as a
  /// signed provider record into its favourite archiver's log. Returns the
  /// hex sha each callsign hosts.
  Future<Map<String, String>> hostSyntheticFiles() async {
    final out = <String, String>{};
    for (final n in nodes) {
      final sha = sha256Of('file-of-${n.callsign}'.codeUnits);
      out[n.callsign] = hexOf(sha);
      final rec = await ProviderRecord.create(
          providerIdentity: n.identity, sha256: sha, capacity: 1);
      larges[n.fav].log.add(rec);
      pubToCall[hexOf(rec.providerPub)] = n.callsign;
    }
    return out;
  }

  /// Add one more real provider record (a file with known bytes) to [holder]'s
  /// favourite archiver, for the cross-archiver resolution scenario.
  Future<void> advertiseReal(SimNode holder, String shaHex) async {
    final rec = await ProviderRecord.create(
        providerIdentity: holder.identity,
        sha256: shaBytesOfHex(shaHex),
        capacity: 1);
    larges[holder.fav].log.add(rec);
    pubToCall[hexOf(rec.providerPub)] = holder.callsign;
  }

  /// The three archivers find each other and sync: a full-mesh pointer-sync
  /// pull (every record verified against its signer), then the public-traffic
  /// catch-up that unions the group spools. Returns records rejected on merge
  /// (must be 0 — a forged record never enters a map). After this every
  /// archiver's [index] and [messages] hold the whole union.
  Future<int> syncLargeArchivers() async {
    var rejected = 0;
    // Seed each archiver's index with its own log.
    for (final a in larges) {
      final own = PointerSyncServer(a.log).answer(a.callsign, 0, max: 100000)!;
      await PointerSyncClient(
        onInsert: (r) async {
          if (!await r.verify()) return false;
          a.index['${hexOf(r.sha256)}|${hexOf(r.providerPub)}'] = r;
          return true;
        },
        onRemove: (k, p) => a.index.remove('$k|$p'),
      ).merge(a.callsign, own.entries, own.nextSeq, own.more);
    }
    // Full-mesh: each pulls every other's log.
    for (final a in larges) {
      for (final b in larges) {
        if (identical(a, b)) continue;
        final batch = PointerSyncServer(b.log).answer(b.callsign, 0, max: 100000)!;
        await PointerSyncClient(
          onInsert: (r) async {
            if (!await r.verify()) {
              rejected++;
              return false;
            }
            a.index['${hexOf(r.sha256)}|${hexOf(r.providerPub)}'] = r;
            return true;
          },
          onRemove: (k, p) => a.index.remove('$k|$p'),
        ).merge(b.callsign, batch.entries, batch.nextSeq, batch.more);
      }
    }
    // Public group traffic converges (§12.9.3 catch-up between archivers).
    final all = larges.expand((l) => l.messages).toSet();
    for (final a in larges) {
      a.messages.addAll(all);
    }
    return rejected;
  }

  /// Holders (callsigns) [a]'s index knows for [shaHex] — what a q:have miss
  /// at [a] would name in `m:try`.
  List<String> holdersAt(LargeArchiver a, String shaHex) => [
        for (final r in a.index.values)
          if (hexOf(r.sha256) == shaHex &&
              pubToCall.containsKey(hexOf(r.providerPub)))
            pubToCall[hexOf(r.providerPub)]!
      ];
}
