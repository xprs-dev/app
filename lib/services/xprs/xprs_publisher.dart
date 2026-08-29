/// Publishing an XPRS packet on every bearer this device has.
///
/// The one place that answers "which transports, right now" — a wapp hands the
/// core CONTENT (`hal_xprs_status`) and this service decides where it travels
/// (docs/architecture.md rule 1: transports are core; a wapp never chooses a
/// radio). Today that is BLE5 extended advertising and a Reticulum broadcast;
/// LoRa holds a visible slot that activates the day the radio exists.
///
/// `scope:` (docs/XPRS.md section 13.11) gates reach: a `local` packet stays
/// on the short-range bearers, a country scope is not gatewayed by a node
/// that cannot place itself, and the default — global — goes everywhere
/// active, which is xprs's stated behaviour.
///
/// Long content splits into section 6.6 parts (at most nine, split only at
/// spaces, same `ts:` throughout) and the signature covers the REASSEMBLED
/// packet, riding the last part (sections 9.1.1 and 25.5). No profile key →
/// transmit unsigned, which the spec permits and the log states.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'dart:typed_data';

import '../../connections/bluetooth/ble5_bus.dart';
import '../mesh/mesh_custody.dart';
import '../mesh/mesh_service.dart';
import '../mesh/mesh_store.dart';
import '../mesh/mesh_transfer_scheduler.dart';
import '../../connections/lora/lora_connection.dart';
import '../../profile/profile_service.dart';
import '../log_service.dart';
import '../preferences_service.dart';
import '../reticulum/rns_service.dart';
import 'xprs_ingest.dart';
import 'xprs_lan.dart';
import 'xprs_airtime.dart';
import '../../util/nostr_crypto.dart';
import 'xprs_archive.dart';
import 'xprs_body.dart';
import 'xprs_group_keys.dart';
import 'xprs_id.dart';
import 'xprs_monitor.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

/// One way bytes can leave this device.
///
/// Deliberately tiny: the publisher asks two questions — are you on, and did
/// you take it — and applies the scope rules itself so every future bearer
/// (LoRa, a KISS TNC, WiFi Aware) inherits them by construction.
/// What a bearer did with one wire.
///
/// `sent` and `refused` are not the only two answers, and pretending they were
/// made the per-lane report untrustworthy. Measured on the bench: a directed
/// wire reported `reticulum: refused` and arrived at the far station over
/// Reticulum a moment later — because that bearer hands the packet to two lanes
/// and could only report one of them. A report that says "refused" about a
/// packet that arrived is worse than no report, since the whole point of it is
/// to answer "where did this actually go".
enum XprsSendResult {
  /// On the air, or acknowledged by the medium.
  sent,

  /// Handed to a lane that stores and forwards, whose answer comes later. Not
  /// a failure and not yet a delivery — the honest third answer.
  queued,

  /// The medium said no to this frame.
  refused,
}

abstract class XprsBearer {
  String get name;

  /// What the spool calls this bearer. Usually the same word; the two that
  /// differ do so because the archive names a medium (`ble`) where the
  /// publisher names a radio generation (`ble5`).
  String get archiveBearer => name;

  /// Whether a `scope:local` packet may use this bearer (section 13.11.1:
  /// local names the short-range bearers, not a distance).
  bool get shortRange;

  Future<bool> get active;

  /// Transmit one wire. [part] distinguishes the parts of a split packet so
  /// an advert-style bearer can rotate them under distinct keys.
  ///
  /// [slot] names WHAT is being aired ('status', 'ask:X3WWAJ', 'identity').
  /// An advert-style bearer keys its rotation entry by it, and re-registering
  /// a key REPLACES that entry's payload — so everything sharing one slot
  /// clobbered everything else. A catch-up sweep asking N stations back to
  /// back put only the LAST ask on air, and a status the user had just
  /// published went with it.
  /// [ttl] is how long an advert-style bearer should keep the frame on air.
  /// Only such a bearer has any use for it -- a datagram is sent once and is
  /// gone -- so it is optional and each bearer falls back to its own default.
  /// It exists because a replayed history page is twelve frames paced 1.5 s
  /// apart: at the advertiser's 120 s default they would all still be on air
  /// long after the page ended, holding twelve rotation slots against
  /// everything else this station has to say.
  Future<XprsSendResult> send(String wire,
      {required int part, String slot = 'status', Duration? ttl});
}

class _Ble5Bearer implements XprsBearer {
  @override
  String get name => 'ble5';
  @override
  String get archiveBearer => 'ble';
  @override
  bool get shortRange => true;
  @override
  // Both halves matter: the controller must do extended advertising at all, and
  // the radio must be on this second. supported() alone is a capability probe
  // cached for the life of the process, so it kept reporting this bearer active
  // with Bluetooth switched off — every ask composed, signed and dropped.
  Future<bool> get active async =>
      await Ble5Bus.instance.supported() && await Ble5Bus.instance.adapterOn();
  @override
  Future<XprsSendResult> send(String wire,
          {required int part, String slot = 'status', Duration? ttl}) async =>
      await Ble5Bus.instance.advertiseFrame(
        'xprs-$slot:$part',
        Ble5Subtype.xprs,
        Uint8List.fromList(utf8.encode(wire)),
        // Long enough to span a receiver's duty-cycled scan burst — the same
        // rationale hal_ble_advertise documents for its 120 s. A caller that
        // knows better (a paced replay) says so.
        ttl: ttl ?? const Duration(seconds: 120),
      )
          ? XprsSendResult.sent
          : XprsSendResult.refused;
}

class _ReticulumBearer implements XprsBearer {
  @override
  String get name => 'reticulum';
  @override
  String get archiveBearer => 'rns';
  @override
  bool get shortRange => false;
  @override
  Future<bool> get active async => RnsService.instance.isUp;
  @override
  Future<XprsSendResult> send(String wire,
      {required int part, String slot = 'status', Duration? ttl}) async {
    // A wire addressed to one station rides the LXMF lane when the network
    // can name that station. The distinction is not cosmetic: wappBroadcast
    // is an ANNOUNCE, and the public community hubs do not cross-forward
    // announces between their own clients -- measured on the bench, every
    // announce between two hub-connected instances arrived by the RNS LAN
    // interface and none by the hub. Links are what the hubs actually
    // forward, LXMF rides links, and it adds store-and-forward for a peer
    // that is away. So a cmd:history, its t:result, and any other d: wire
    // take the addressed lane, which is also section 36.0's path rule --
    // the most reliable path that reaches the asker. Undirected publications
    // keep the broadcast: whoever is in announce reach hears them.
    final bytes = Uint8List.fromList(utf8.encode(wire));
    final dest = XprsPacket.parse(wire)?['d']?.trim() ?? '';
    if (dest.isNotEmpty) {
      final hex = RnsService.instance.lxmfDestForCallsign(dest);
      if (hex.isNotEmpty) {
        // Belt and braces, because these two lanes fail differently. The wapp
        // datagram is cheap and usually right; LXMF rides a LINK, and links
        // are what the public hubs actually forward between their own clients
        // (36.12.1). Measured on the bench: two phones on different networks
        // exchanged LXMF happily while the datagram lane stayed silent, so a
        // cmd:history ask sent only on the datagram was never answered. Both
        // copies carry the same section 5 identifier and collapse on arrival.
        unawaited(RnsService.instance
            .sendLxmf(destHex: hex, title: 'xprs', content: wire)
            .catchError((_) => false));
        // `wappSendTo` true means delivered on a link. False does NOT mean
        // nothing went: the LXMF copy above is still in flight, and on the
        // bench it is the one that arrives when the datagram lane is silent.
        // So the answer is `queued` — handed to a store-and-forward lane whose
        // outcome is not known yet — rather than `refused`, which said a
        // packet had not gone while it was arriving.
        return await RnsService.instance.wappSendTo('xprs', hex, bytes)
            ? XprsSendResult.sent
            : XprsSendResult.queued;
      }
    }
    return await RnsService.instance.wappBroadcast('xprs', bytes)
        ? XprsSendResult.sent
        : XprsSendResult.refused;
  }
}

class _LanBearer implements XprsBearer {
  @override
  String get name => 'lan';
  @override
  String get archiveBearer => 'lan';
  // The wire in the building is short-range in the sense section 13.11.1
  // means: a `scope:local` packet on it reaches the machines here and stops.
  @override
  bool get shortRange => true;
  @override
  Future<bool> get active async => XprsLan.instance.up;
  @override
  Future<XprsSendResult> send(String wire,
          {required int part, String slot = 'status', Duration? ttl}) async =>
      // The socket accepted it. A UDP broadcast is never acknowledged, so this
      // is the most any LAN send can honestly claim.
      XprsLan.instance.send(wire)
          ? XprsSendResult.sent
          : XprsSendResult.refused;
}

class _LoraBearer implements XprsBearer {
  // The slot the user asked to see: when a LoRa radio ships, its connection
  // reports available and statuses start riding it with no publisher change.
  final LoraConnection _lora = LoraConnection();
  @override
  String get name => 'lora';
  @override
  String get archiveBearer => 'lora';
  @override
  bool get shortRange => true;
  @override
  Future<bool> get active async =>
      _lora.status == LoraStatus.available;
  @override
  Future<XprsSendResult> send(String wire,
          {required int part, String slot = 'status', Duration? ttl}) async =>
      XprsSendResult.refused;
}

/// What one fan-out did: the per-bearer verdicts, and the first bearer that
/// actually carried the packet (the label the archive files it under).
class _Air {
  const _Air(this.report, this.carriedBy);
  final Map<String, String> report;
  final String? carriedBy;
  bool get anySent => report.values.any((v) => v == 'sent');
}

class XprsPublisher {
  XprsPublisher._();
  static final XprsPublisher instance = XprsPublisher._();

  /// Replaceable for tests; order is presentation only (every active bearer
  /// is used).
  List<XprsBearer> bearers = [
    _Ble5Bearer(),
    _LanBearer(),
    _ReticulumBearer(),
    _LoraBearer()
  ];

  int published = 0;

  /// Bearers switched off by the operator or by a test, by [XprsBearer.name].
  ///
  /// **In memory only, and deliberately so.** This is an instrument: it exists
  /// so a lane can be taken away while the station keeps running, and the
  /// station's reaction observed — the fallback in [_fanOut], the custody park,
  /// the retry ladder. A disabled bearer reports `disabled`, which is a third
  /// thing from `inactive` (the radio is off) and `refused` (the radio said
  /// no), because those three mean different things to whoever reads the
  /// report. It resets on restart so a forgotten switch cannot silently
  /// half-mute a station for ever.
  final Set<String> _disabled = <String>{};

  Set<String> get disabledBearers => Set.unmodifiable(_disabled);

  bool isBearerEnabled(String name) => !_disabled.contains(name.toLowerCase());

  /// Will a GATT/MSP session carry this to [dest] instead of the air?
  ///
  /// Two questions, and both must be yes. *Will the peer take it* is the
  /// peer's own declaration from its last MSP HELLO, on the very lane that
  /// would carry it — not a guess from a device class, and it lets a board
  /// exclude itself, which every ESP32 does today. *Did the queue accept it*
  /// matters because the store IS the session's outbox: `_drainCustody` pulls
  /// from it, so a wire that is not in the store is a wire the session will
  /// never send.
  ///
  /// Returns false on any doubt, and false means "air it as before". A wrong
  /// suppression is silence until the 120 s sweep re-airs it; an unnecessary
  /// broadcast is one advert. The asymmetry decides the default.
  bool _sessionTakes(String dest) {
    final ask = MeshSessionManager.instance.hooks.canTakeCustody;
    if (ask == null || !ask(dest)) return false;
    final store = MeshStore.instance;
    if (!store.ready) return false;
    final self = MeshService.instance.tableCallsign.trim();
    if (self.isEmpty) return false;
    var took = false;
    for (final w in _sessionPending) {
      if (store.offer(
          target: dest,
          sender: self,
          wire: Uint8List.fromList(utf8.encode(w)),
          urg: MeshUrgency.normal,
          ours: true)) {
        took = true;
      }
    }
    if (!took) return false;
    MeshTransferScheduler.instance.pokeFor(dest);
    LogService.instance.add(
        'XPRS: $dest is next to us — ${_sessionPending.length} wire(s) handed '
        'to the session, not aired');
    return true;
  }

  /// The wires the current fan-out is placing, so [_sessionTakes] can queue
  /// every part rather than only the one a bearer happens to be looking at.
  List<String> _sessionPending = const [];

  /// Returns true when the name matched a bearer this station actually has.
  bool setBearerEnabled(String name, bool enabled) {
    final n = name.toLowerCase().trim();
    if (!bearers.any((b) => b.name == n)) return false;
    if (enabled) {
      _disabled.remove(n);
    } else {
      _disabled.add(n);
    }
    LogService.instance
        .add('XPRS: bearer $n ${enabled ? "enabled" : "DISABLED"} by request');
    return true;
  }

  /// Put [wires] on the air and say what each bearer did with them.
  ///
  /// **The one fan-out.** There used to be four copies of this loop — one per
  /// public method — and they had drifted: two applied the scope gate and two
  /// did not, only one supported `ttl`, only one split into section 6.6 parts,
  /// and they disagreed three ways about when to file our own copy. Every cell
  /// that differed was a decision made once, in one method, that the other
  /// three never learned. Notably `publishMailboxDecl` and `publishStatus` both
  /// fell through to the advert slot `status`, so a mailbox declaration evicted
  /// the discovery beacon from the air.
  ///
  /// [prefer] names the bearer to try first (section 36.0's path choice). When
  /// it carries the packet the others are not used; when it does not, every
  /// bearer is tried after all, because a preference that can become silence is
  /// not a preference — 36.0's own words are "if the arrival bearer cannot carry
  /// the answer it does not give up".
  Future<_Air> _fanOut(
    List<String> wires, {
    required String slot,
    Duration? ttl,
    String? prefer,
    bool urgent = false,
  }) async {
    final report = <String, String>{};
    String? carriedBy;

    // A packet's own scope decides which bearers may carry it at all
    // (section 13.11.1: `local` names bearers, not a distance). Read from the
    // first wire; every part of a split message repeats the envelope.
    final p0 = XprsPacket.parse(wires.first);
    final local = p0 != null && xprsScope(p0).scope != XprsScope.global;
    _sessionPending = wires;

    // Who this is for, if it is for one station. Read once: every part of a
    // split repeats the envelope.
    final dest = (p0?['d'] ?? '').trim().toUpperCase();

    Future<bool> tryOne(XprsBearer b) async {
      if (_disabled.contains(b.name)) {
        report[b.name] = 'disabled';
        return false;
      }
      // A 1:1 to a phone in the room takes the session, not the street.
      //
      // The advert window is five seconds a minute shared by every registered
      // frame, so airing a packet meant for one station spends the whole
      // room's airtime on two stations' business — a history replay is a dozen
      // adverts, and past about ten XPRS devices in range that is what makes
      // the channel unusable for everyone.
      //
      // This is the check the custody tap could never make: that tap lives in
      // BleService.enqueueAdvert, and this bearer calls Ble5Bus.advertiseFrame
      // directly, so a `cmd:history` went out as a broadcast however wide the
      // tap's gate was opened. Measured on the bench: both phones reported
      // ble5:sent and a third station witnessed both asks.
      //
      // Only this bearer, so a peer reachable another way still is: the other
      // lanes are untouched and "no better bearer" holds by itself. And only
      // when the peer has DECLARED it will take the handover — every ESP32
      // today says no, so boards need no special-casing.
      if (b.name == 'ble5' && dest.isNotEmpty && _sessionTakes(dest)) {
        report[b.name] = 'session';
        return false;
      }
      if (local && !b.shortRange) {
        // A local packet never leaves the short-range bearers (13.11.1), and a
        // node that cannot place itself does not gateway a country scope
        // (13.11.3) — both land here.
        report[b.name] = 'scope';
        return false;
      }
      if (!await b.active) {
        report[b.name] = 'inactive';
        return false;
      }
      // §31.1: this bearer may still owe silence for what it last transmitted,
      // and a retry costs exactly what the first airing did. Deferred, never
      // dropped — the caller keeps its own cadence and comes back.
      if (!urgent && XprsAirtime.instance.owedBy(b.name) > 0) {
        report[b.name] = 'deferred';
        xprsLogDeferral(slot, b.name, XprsAirtime.instance.owedBy(b.name));
        return false;
      }
      // Worst answer across the parts wins: a message whose third part was
      // refused did not go, whatever the first two did.
      var worst = XprsSendResult.sent;
      for (var i = 0; i < wires.length; i++) {
        final r = await b.send(wires[i], part: i + 1, slot: slot, ttl: ttl);
        if (r.index > worst.index) worst = r;
      }
      report[b.name] = worst.name;
      // `queued` still names the lane the packet is travelling on, so the
      // archive files it there — but it does NOT satisfy a path preference,
      // because we do not yet know it arrived and the point of choosing one
      // path is that it works.
      if (worst != XprsSendResult.refused) {
        carriedBy ??= b.archiveBearer;
        XprsAirtime.instance.charge([b.name], packets: wires.length);
      }
      return worst == XprsSendResult.sent;
    }

    var done = false;
    if (prefer != null) {
      final pick = bearers.where((b) => b.name == prefer);
      if (pick.isNotEmpty) done = await tryOne(pick.first);
    }
    for (final b in bearers) {
      if (done && b.name == prefer) continue;
      if (done) {
        report[b.name] = 'unused';
        continue;
      }
      await tryOne(b);
    }
    return _Air(report, carriedBy);
  }
  int refused = 0;

  /// Publish a `t:status` (section 27). Returns per-bearer outcomes:
  /// 'sent' | 'refused' | 'inactive' | 'scope' — empty map when nothing
  /// could be published at all (no profile, empty text).
  Future<Map<String, String>> publishStatus(String text,
      {String? mood, String? scope}) async {
    final body = text.trim();
    final call =
        (ProfileService.instance.activeProfile?.callsign ?? '').trim();
    if (body.isEmpty || call.isEmpty) {
      refused++;
      LogService.instance.add(
          'XPRS: status not published — ${body.isEmpty ? "empty" : "no profile callsign yet"}');
      return const {};
    }

    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${now.year}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';

    var head = 't:status f:${call.toUpperCase()} ts:$ts';
    if (mood != null && mood.trim().isNotEmpty) {
      head += ' mood:${mood.trim().toLowerCase()}';
    }
    if (scope != null && scope.trim().isNotEmpty) {
      head += ' scope:${scope.trim()}';
    }

    final wires = _wires(head, body);
    if (wires.isEmpty) {
      refused++;
      return const {};
    }

    final air = await _fanOut(wires, slot: 'status');
    final report = air.report;
    final carriedBy = air.carriedBy;

    // Push to the super-archivers this operator CHOSE (36.3, 36.4).
    //
    // A public wire goes out as a broadcast announce, and the community hubs
    // do not cross-forward those between their own clients -- so a station
    // whose neighbours are all on the far side of the internet published into
    // silence. A super-archiver is the one place that holds everything
    // everybody said (36.9.4), which is what makes Global chat global: every
    // other station pulls it from there. Pushing is one addressed copy per
    // configured super, on the lane the hubs do carry (36.12.1), and only for
    // wires meant for everybody -- mail has a d: and its own custody path.
    final supers =
        PreferencesService.instanceSync?.xprsSuperArchivers ?? const <String>[];
    if (supers.isNotEmpty) {
      for (final w in wires) {
        final p = XprsPacket.parse(w);
        if (p == null || (p['d'] ?? '').trim().isNotEmpty) continue;
        for (final call in supers) {
          final hex = RnsService.instance.lxmfDestForCallsign(call);
          if (hex.isEmpty) continue;
          unawaited(RnsService.instance
              .sendLxmf(destHex: hex, title: 'xprs', content: w)
              .catchError((_) => false));
        }
      }
    }

    // Our own publication enters our own spool whether or not a radio took
    // it. A cmd:history asked of the author must be able to replay the author
    // (section 36.5), and the words exist either way: this used to be gated on
    // `carriedBy != null`, so a status composed with no bearer active was
    // never stored, never shown, and reported no error. The bearer records
    // what actually carried it, or `none` when nothing did — an honest row
    // rather than an absent one.
    //
    // Written once per wire AFTER the send loop, deliberately: the ON CONFLICT
    // clause in the archive does not update `bearer` and does increment
    // `heard`, so recording first and amending later would leave the bearer
    // empty and count one packet as heard twice.
    for (final w in wires) {
      XprsIngest.own(w, bearer: carriedBy ?? 'none');
    }

    published++;
    LogService.instance.add('XPRS: status (${wires.length} part'
        '${wires.length == 1 ? "" : "s"}) — ${report.entries.map((e) => "${e.key}:${e.value}").join(", ")}');
    return report;
  }

  /// Publish this station's `t:mailbox hold:` declaration (section 13.12):
  /// the stations mail for us should be left with, in preference order.
  /// MUST be signed -- a forged declaration steals mail, so with no signing
  /// key nothing is aired and the log says why. Returns per-bearer outcomes.
  Future<Map<String, String>> publishMailboxDecl(String holdCsv) async {
    final call =
        (ProfileService.instance.activeProfile?.callsign ?? '').trim();
    final hold = holdCsv
        .split(',')
        .map((c) => c.trim().toUpperCase())
        .where((c) => c.isNotEmpty)
        .join(',');
    if (call.isEmpty || hold.isEmpty) return const {};

    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${now.year}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';

    var p = XprsPacket.parse(
        't:mailbox f:${call.toUpperCase()} ts:$ts hold:$hold');
    if (p == null || !p.fits) return const {};
    final d = xprsProfileScalar();
    if (d == null) {
      LogService.instance.add(
          'XPRS: mailbox declaration NOT aired — no signing key, and an '
          'unsigned one must be ignored (13.12)');
      return const {};
    }
    p = xprsSign(p, d);
    final wire = p.encode();

    // Its OWN slot. This used to fall through to the bearer-side default,
    // `status`, and a slot is a rotation key on BLE5 — one frame per slot — so
    // a mailbox declaration evicted the discovery beacon from the air.
    final air = await _fanOut([wire], slot: 'mailbox');
    final report = air.report;
    final carriedBy = air.carriedBy;
    if (carriedBy != null) XprsIngest.own(wire, bearer: carriedBy);
    LogService.instance.add('XPRS: mailbox hold:$hold — '
        '${report.entries.map((e) => "${e.key}:${e.value}").join(", ")}');
    return report;
  }

  /// Announce the key this callsign signs with (section 9.3).
  ///
  /// Until this existed no station could check a single signature of ours, so
  /// every packet we sent read `unverified` and every station metered us as a
  /// stranger — two history replays an hour instead of six (section 31.2).
  ///
  /// MUST be self-signed. The signature proves we hold the private half, which
  /// is not circular (section 9.3): without one, anybody can rebroadcast our
  /// callsign with our real key and whatever else they like attached. Both
  /// station firmwares drop an identity whose signature does not verify
  /// against the `k:` it carries, so an unsigned one binds nothing anywhere
  /// and is not aired.
  ///
  /// Deliberately carries NO `scope:`, so it is global and rides every active
  /// bearer. A key binding is not a local fact.
  ///
  /// `nick:` is deliberately omitted: the key-binding form is 171 bytes and
  /// the smallest controller measured in docs/ble5.md section 3 carries 184,
  /// where an oversized frame is refused rather than truncated.
  Future<Map<String, String>> publishIdentity() async {
    final profile = ProfileService.instance.activeProfile;
    final call = (profile?.callsign ?? '').trim().toUpperCase();
    final npub = (profile?.npub ?? '').trim();
    if (call.isEmpty || !npub.startsWith('npub1')) return const {};

    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${now.year}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';

    var p = XprsPacket.parse('t:identity f:$call ts:$ts k:$npub');
    if (p == null) return const {};
    final d = xprsProfileScalar();
    if (d == null) {
      LogService.instance.add(
          'XPRS: identity NOT aired — no signing key (locked profile?), and '
          'an unsigned identity binds nothing (9.3)');
      return const {};
    }
    p = xprsSign(p, d);
    if (!p.fits) return const {};
    final wire = p.encode();

    final air = await _fanOut([wire], slot: 'identity');
    final report = air.report;
    final carriedBy = air.carriedBy;
    // 'none' rather than skipping: a period where the identity reached nobody
    // is a fact worth having in the spool.
    XprsIngest.own(wire, bearer: carriedBy ?? 'none');
    LogService.instance.add('XPRS: identity $call k:${npub.substring(0, 12)}… '
        '— ${report.entries.map((e) => "${e.key}:${e.value}").join(", ")}');
    return report;
  }

  /// Publish one caller-composed wire (spec/API-HTTP.md send semantics):
  /// validate section 4 syntax, sign it when it speaks as this station and
  /// carries no sig, apply the scope rules, air on every active bearer and
  /// spool our own copy. The caller owns the content.
  ///
  /// [slot] keeps concurrent publishes in separate advert rotation entries.
  /// It defaults to the packet's own type and destination, so two asks to two
  /// stations no longer overwrite each other and neither touches the status
  /// slot. Pass one explicitly only to group wires deliberately.
  /// Put one caller-composed wire on every bearer that will take it.
  ///
  /// [verbatim] is for a wire this station did not write: a history replay
  /// re-airs the AUTHOR's packet, byte for byte, with the author's own
  /// signature (25.2.1, 36.2). Two things that are right for our own words
  /// are wrong for someone else's, and both are skipped:
  ///   - signing. The wire's identifier is derived from its bytes, so adding
  ///     a signature to a stored record renames it, and the asker's `until:`
  ///     continuation would then be paging a record nobody else has.
  ///   - filing it as ours. It is already in the spool as something we HEARD;
  ///     re-entering it through [XprsIngest.own] would claim authorship of
  ///     another station's packet.
  /// The exact wire the last [publishWire] put on the bearers -- signed
  /// when signing applied. For a caller that needs the same bytes for
  /// custody (a parked copy must match what the air carries, or the
  /// receipt's identifier will not).
  String? lastWire;

  Future<Map<String, String>> publishWire(String wireIn,
      {String? slot,
      Duration? ttl,
      bool verbatim = false,
      /// Force the section 36.0 path choice instead of deriving it from
      /// evidence.
      ///
      /// The caller that has better evidence than the monitor does: §36.8.1
      /// releases held mail "on the bearer X was heard on, which is the
      /// freshest possible evidence of a working path". A packet that just
      /// arrived from a station beats anything a beacon can say about it.
      ///
      /// Falls back to the fan-out like any other preference when the named
      /// bearer does not carry it.
      String? prefer}) async {
    LogService.instance.add('XPRS: publishWire <- $wireIn');
    var p = XprsPacket.parse(wireIn.trim());
    if (p == null || !p.fits) {
      LogService.instance.add('XPRS: publishWire rejected (parse/fit)');
      return const {};
    }
    final call =
        (ProfileService.instance.activeProfile?.callsign ?? '').trim();
    final from = (p['f'] ?? '').toUpperCase();
    if (!verbatim &&
        call.isNotEmpty &&
        from.split('-').first == call.toUpperCase().split('-').first &&
        !p.has('sig')) {
      final d = xprsProfileScalar();
      if (d != null) p = xprsSign(p, d);
    }
    final wire = p.encode();
    lastWire = wire;
    // `<type>` alone would still collide across destinations, which is exactly
    // the catch-up sweep's case: N asks, one slot, one survivor.
    //
    // And `<type>:<dest>` still collides across RECORDS to one destination.
    // Registering a slot REPLACES the frame in it, so a run of acts addressed
    // to the same group left at most the last one on air: three grants to
    // `X5A3F2` all keyed `moderate:X5A3F2`, two of them overwritten before the
    // rotation ever reached them. That is fine for a packet that supersedes
    // its predecessor -- a beacon, a status -- and wrong for one that is a
    // distinct record. A roster act is a record: losing one loses a member.
    //
    // So a record keys on its own section 5 identifier. Bounded by the TTL
    // rather than by the slot name, which is the correct bound: it holds a
    // rotation slot for as long as it is worth airing and no longer.
    final dest = (p['d'] ?? '').toUpperCase();
    const perRecord = {'moderate'};
    final useSlot = slot ??
        (perRecord.contains(p.type)
            ? '${p.type}:${xprsIdentifier(p)}'
            : dest.isEmpty
                ? p.type
                : '${p.type}:$dest');

    // Section 36.0: "The one place a bearer legitimately decides anything is
    // choosing among several paths to the SAME station." When this packet names
    // a station we have recent per-peer evidence for, take the best of those
    // paths instead of every path -- and when we have no such evidence, fan out,
    // which is that same section's own fallback ("Where a station cannot tell
    // which path reaches the asker ... it answers on every bearer it can
    // transmit on").
    final chosen = prefer ?? _preferredBearer(p, dest);

    // §31.2: "it may never hold back the control packets, because a code:404 or
    // code:429 that does not arrive is indistinguishable from a station that is
    // simply not there." A receipt is the same case — it is what releases every
    // carrier holding the message, so a deferred one leaves a chain of stations
    // holding mail that has already arrived. And §13.1 gives sos and warning
    // nine relays precisely because they are worth spending a shared channel on.
    const never = {'result', 'receipt', 'sos', 'warning'};
    final air = await _fanOut([wire],
        slot: useSlot,
        ttl: ttl,
        prefer: chosen,
        urgent: never.contains(p.type));
    final report = air.report;
    final carriedBy = air.carriedBy;

    final took = carriedBy;
    // File it as ours when we WROTE it -- which is not the same question as
    // whether we signed it with the profile key.
    //
    // `verbatim` means "do not sign, do not claim authorship", and for a
    // history replay both halves are right. For a group act both halves are
    // wrong in the second: the packet is signed by a key THIS STATION HOLDS
    // (section 26.1 -- the key belongs to the group, and the admin is whoever
    // holds it), so it is our own record and nobody else will keep it for us.
    // Bench: neither phone held a single `moderate` row, including the one
    // that composed them, so there was nothing to serve and propagation was
    // dead at the source.
    //
    // The same is true of the OTHER half of a group's record. 26.3.1's
    // acceptance and departure are signed by the PERSON, so `f:` is our own
    // callsign rather than a group we hold a key for — and asking only the
    // group-key question threw them away. Bench: the phone accepted an
    // invitation, both screens agreed, and after a restart it was back to
    // `invited` while the admin still had it as a member, because the one
    // station that had to keep that consent was the one that gave it.
    final ours = !verbatim ||
        XprsGroupKeys.instance.scalarFor(from) != null ||
        from ==
            NostrCrypto.bareCallsign(XprsArchive.instance.selfCallsign)
                .toUpperCase();
    if (ours && took != null) {
      XprsIngest.own(wire, bearer: took);
    }
    published++;
    // One line per caller-composed wire: which bearers took it. A wire that
    // silently reached nobody is the failure mode that costs a day.
    LogService.instance.add(
        'XPRS: ${p.type} wire — ${report.entries.map((e) => '${e.key}:${e.value}').join(', ')}');
    return report;
  }

  /// Test seam: the exact wire [publishIdentity] would air, with [signingKey]
  /// standing in for the profile key (a unit test has no profile).
  String? debugIdentityWire(
      {required String call, required String npub, required BigInt signingKey, String? ts}) {
    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = ts ??
        '${now.year}-${two(now.month)}-${two(now.day)}_'
            '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    final p = XprsPacket.parse('t:identity f:$call ts:$stamp k:$npub');
    if (p == null) return null;
    final signed = xprsSign(p, signingKey);
    return signed.fits ? signed.encode() : null;
  }


  /// Bearers this station can reach a peer over, best first.
  ///
  /// Section 36.0 ranks by "the highest usable bandwidth among those it has
  /// recent evidence are working", with the tie-break stated outright:
  /// "Reliability outranks raw speed -- a fast path that has not carried
  /// anything lately is a guess, and a slower one that answered a minute ago is
  /// knowledge." Hence evidence gates the list and bandwidth only orders what
  /// survives.
  ///
  /// A LAN is one operator's own switch: no hop budget, no shared duty cycle,
  /// no stranger's transport in the middle. BLE5 next -- in the room, but five
  /// seconds of transmit a minute (docs/ble5.md section 1). Reticulum last for
  /// a peer we can hear directly: it is the internet path, and eighteen hops
  /// through community hubs to reach a phone on the same desk is the case this
  /// ranking exists to stop.
  static const List<String> _byBandwidth = ['lan', 'ble5', 'reticulum'];

  /// How recent a sighting has to be to count as evidence of a working path.
  /// Three beacon periods, the same window `RnsService._peerReachable` uses, so
  /// one missed beacon does not demote a peer that is simply having a bad
  /// minute.
  static const int _evidenceMs = 3 * 60 * 1000;

  /// The single bearer to use for [p], or null to fan out.
  String? _preferredBearer(XprsPacket p, String dest) {
    // Only a DIRECTED packet has one station to choose a path to. A broadcast
    // has no "same station" to rank paths for, and section 36.0's rule does not
    // reach it.
    if (dest.isEmpty) return null;
    // A group is several stations behind one name, so the paths are not to the
    // same place. Callsigns start X1/X3/X4/X5 or are authority-issued; a group
    // name is neither, and either way fanning out is the safe answer.
    if (!_looksLikeCallsign(dest)) return null;
    final st = XprsMonitor.instance.stations[dest];
    if (st == null) return null;
    // What the station SAYS it is on (its beacon's `link:`, section 10.6.1) --
    // not the bearer its packets happened to arrive over, which is a statement
    // about whoever re-aired them. See `XprsStation.bearersDeclared`.
    final fresh = st
        .declaredBearersFresh(DateTime.now().millisecondsSinceEpoch, _evidenceMs)
        .toSet();
    if (fresh.isEmpty) return null;
    for (final want in _byBandwidth) {
      if (fresh.contains(want)) return want;
    }
    // Heard, but on nothing we rank -- say nothing and let every bearer try.
    return null;
  }

  static bool _looksLikeCallsign(String d) =>
      RegExp(r'^(X[1345][A-Z0-9]{2,5}|[A-Z0-9]{1,3}[0-9][A-Z0-9]*)(-[0-9]{1,2})?$')
          .hasMatch(d);

  /// Ask [call] for its key binding, section 18.1: "`q:identity` (section 7)
  /// asks for one directly rather than waiting for the next period."
  ///
  /// Without this, a station that has never heard a peer's `t:identity` -- or
  /// has restarted and holds nothing for a peer it has never archived -- waits
  /// up to thirty minutes before it can seal a private message to them (9.2) or
  /// verify anything they sign. One directed packet buys that back.
  ///
  /// Throttled per callsign, because the answer takes a moment to arrive and a
  /// composer retrying a send would otherwise ask on every keystroke.
  /// The ask climbs the shared ladder like every other repeated transmission
  /// (§31.1: a retry is not a new packet). This used to be a private map and a
  /// 60-second constant — the twelfth such timer in the codebase, each correct
  /// alone and none aware of the others.
  static const List<int> _identityLadderS = [60, 300, 1800];

  Future<void> askIdentity(String call) async {
    final c = call.trim().toUpperCase();
    if (c.isEmpty) return;
    final key = 'qidentity:$c';
    // Reachable enough to be worth asking: we have heard this station at all.
    // §13.7.2 — asking into a room the peer walked out of teaches nothing.
    final reachable = XprsMonitor.instance.stations[c] != null;
    if (!XprsRetryLedger.instance
        .may(key, reachable: reachable, ladderS: _identityLadderS)) {
      return;
    }
    XprsRetryLedger.instance.spend(key);
    final self = XprsArchive.instance.selfCallsign.trim();
    if (self.isEmpty) return;
    final t = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${t.year}-${two(t.month)}-${two(t.day)}_'
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    // Section 7: a question is `t:request` carrying `q:`.
    final wire = 't:request f:$self d:$c ts:$ts q:identity';
    LogService.instance.add('XPRS: asking $c for its identity (18.1)');
    await publishWire(wire, slot: 'qidentity:$c');
  }

  /// Test seam: exactly the wires [publishStatus] would air for [head] and
  /// [body], with [signingKey] standing in for the profile key (a unit test
  /// has no profile).
  List<String> debugWires(String head, String body, {BigInt? signingKey}) =>
      _wires(head, body, signingKey: signingKey);

  /// The wires to air: one signed packet when it fits, else section 6.6
  /// parts with the reassembled packet's signature on the last (9.1.1).
  List<String> _wires(String head, String body, {BigInt? signingKey}) {
    final d = signingKey ?? xprsProfileScalar();

    XprsPacket? make(String m) => XprsPacket.parse('$head m:$m');

    // The unsplit packet, signed, when it fits.
    final whole = make(body);
    if (whole == null) return const [];
    final signedWhole = d != null ? xprsSign(whole, d) : whole;
    if (signedWhole.fits) return [signedWhole.encode()];

    // Split at spaces only (6.6). Every part reserves room for `n:i/9` AND
    // the signature, so whichever part ends up last still fits after the
    // sig is attached — a uniform budget beats a two-pass fit.
    final probe = make('')!.with_('n', '9/9').with_('sig', 'x' * 60);
    final capacity = XprsPacket.maxBytes - probe.byteLength;
    if (capacity <= 0) return const [];

    final chunks = xprsChunkAtSpaces(body, capacity);

    if (chunks.length > 9) {
      // Nine parts is the format's ceiling (6.6); content past it is a
      // document, and a status is not one. Cut and say so.
      LogService.instance.add(
          'XPRS: status longer than nine parts — cut at part 9');
      chunks.removeRange(9, chunks.length);
    }

    // The signature covers the REASSEMBLED packet: joined m:, no n:.
    final joined = make(chunks.join(' '))!;
    final sig = d != null ? xprsSign(joined, d)['sig'] : null;

    final n = chunks.length;
    final out = <String>[];
    for (var i = 0; i < n; i++) {
      var part = make(chunks[i])!.with_('n', '${i + 1}/$n');
      if (i == n - 1 && sig != null) part = part.with_('sig', sig);
      out.add(part.encode());
    }
    return out;
  }
}
