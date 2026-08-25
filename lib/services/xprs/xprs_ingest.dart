/*
 * xprs_ingest — the one funnel every heard XPRS packet passes through.
 *
 * Display, archive and command handling used to be one call each at three
 * different receive sites, which is how they drift apart. Now a receive site
 * calls [heard] and this file decides who gets the packet:
 *
 *   monitor — unchanged, with its own bearer allowlist (internet never enters
 *             the live view, and a custody session is not a sighting)
 *   archive — the persistent spool (xprs_archive.dart), when the owner has it
 *             on, which is the default
 *   history — a `t:command cmd:history d:us` is an ask, not traffic (the
 *             responder registers itself in [onCommand])
 *
 * The Reticulum lane is different on purpose ([reticulum]): radio traffic is
 * bounded by radio range, internet traffic is not, so a packet arriving over
 * a hub is archived ONLY when its author declared this station as a mailbox
 * (`t:mailbox hold:` — docs/XPRS.md section 13.12) or the packet is mail to a
 * station that did. Without that rule a well-connected hub would spool the
 * whole mesh's chatter and fill its disk with strangers (section 36.3: a
 * station pushes to the indexers its operator CHOSE).
 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:hex/hex.dart';

import '../../util/nostr_crypto.dart';
import '../log_service.dart';
import '../preferences_service.dart';
import 'xprs_archive.dart';
import 'xprs_gossip.dart';
import 'xprs_monitor.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

class XprsIngest {
  XprsIngest._();

  /// Set by XprsHistoryServer so a heard command reaches the responder
  /// without this file importing it (and without the responder having to
  /// listen on three radios itself).
  static void Function(XprsPacket p,
      {required String selfBase, required String bearer})? onCommand;

  /// Every heard `t:result`, for whoever asked the question it answers --
  /// the catch-up poller advances its watermark on these (36.10.1).
  static void Function(XprsPacket p)? onResult;

  /// A packet from [from] was archived. The catch-up poller uses it to tell a
  /// pull that returned rows from one that returned nothing -- the signal its
  /// cadence runs on, and one the delivery hook cannot give it, because a
  /// broadcast is addressed to nobody.
  static void Function(String from, int? tsMs)? onArchived;

  /// Set by RnsService, which owns the callsign→key map, so a `t:identity`
  /// heard on any bearer lands in the same place a key learned from an
  /// announce does. Same reasoning as [XprsArchive.keyResolver]: this file
  /// stays free of the node.
  static void Function(String callsign, String pubkeyHex)? onIdentity;

  /// A station heard DIRECTLY (no `via:`), on a bearer a radio person would
  /// recognise. Set by MeshService to the release-on-hearing trigger of
  /// section 36.8.1 -- the receiver throttles and checks for held mail; this
  /// funnel only reports the fact.
  static void Function(String callsign, String bearer)? onDirectHeard;

  /// A `t:message` for a THIRD party, off the Reticulum lane -- somebody is
  /// handing this station mail to hold (36.7) or to move along (36.8.1).
  /// Set by MeshService to the custody park + forwarder.
  static void Function(String wire, String target)? onCarry;

  /// A `t:message` addressed to us, on any bearer. Set by MeshService to the
  /// courier's delivery entry point, which verifies, unseals and hands it to
  /// the ordinary inbox. Injected the same way as [onIdentity] so this file
  /// stays free of the mesh.
  static void Function(XprsPacket p, String bearer)? onDeliver;

  /// Packets refused off the Reticulum lane for want of a declaration —
  /// the observable that says the admission rule is alive.
  static int refusedRns = 0;
  static int _lastRefuseLogMs = 0;

  /// The person, with any device suffix removed: `X1ABCD-1` -> `X1ABCD`
  /// (spec section 3.1). One definition, shared, so the person/device
  /// split cannot drift between the archive, the ingest and the server.
  static String _base(String c) => NostrCrypto.bareCallsign(c);

  /// The archive's name for how a packet arrived. A custody session and the
  /// overheard mesh both run over a BLE link — physically local, so they
  /// belong in the spool even though the monitor's sighting ring (rightly)
  /// refuses 'custody' as a bearer a person watches.
  static String _archiveBearer(String bearer) =>
      (bearer == 'mesh' || bearer == 'custody') ? 'ble' : bearer;

  /// Presence: true of a packet that says somebody is there and nothing else.
  ///
  /// These repeat forever by design -- that is what makes them presence -- so
  /// on a pocket device they are the whole storage cost and none of the value.
  /// They still reach XprsMonitor, which is what the graph, the Traffic screen
  /// and the station list read, so nothing on screen depends on spooling them.
  static bool _isPresence(String type) =>
      type == 'observation' || type == 'identity' || type == 'service';

  /// Whether this packet is worth the write.
  ///
  /// The responder already answers a `cmd:history` from XprsArchive.kXprsTalk
  /// when the asker names no `kind:` -- so without this the archive was
  /// storing, pruning and paying for rows the station had already decided it
  /// would never serve.
  static bool _worthKeeping(XprsPacket p, {required bool forUs}) {
    if (forUs) return true; // our own mail, whatever shape it takes
    if (!_isPresence(p.type)) return true; // conversation, always
    final prefs = PreferencesService.instanceSync;
    // A super-archiver's stock in trade IS the chatter: signed observations
    // are the wires a `cmd:history kind:observation only:X` replay serves
    // (36.9.4's bulk gossip). A super that discards them answers every such
    // ask with a 404 by construction, whatever its gossip table knows —
    // gossip stores digests, and a replay may only re-air original packets
    // (36.1).
    if (prefs?.xprsSuperArchiver ?? false) return true;
    return prefs?.xprsKeepChatter ?? false;
  }

  static bool get _archiveOn =>
      PreferencesService.instanceSync?.xprsArchive ?? true;

  /// A packet heard over the air or over a local link. The complete receive
  /// surface calls this: BLE 0x41, BLE 0x58, and the courier's session lane.
  static void heard(
    XprsPacket p, {
    required String bearer,
    required String selfCallsign,
    int rssi = 0,
  }) {
    XprsMonitor.instance
        .offer(p, bearer: bearer, selfCallsign: selfCallsign, rssi: rssi);

    // Exact-callsign skip, NOT base: our own echo is noise, but another of
    // our devices (X1SELF-2, section 3.1) is a station whose traffic — and
    // whose cmd:history asks — are as real as anyone's.
    final self = selfCallsign.trim().toUpperCase();
    final from = (p['f'] ?? '').trim().toUpperCase();
    if (from.isEmpty || from == self) return;

    // A mailbox declaration heard on the street counts exactly like one that
    // arrived over a hub: the author is saying where their mail may rest.
    if (p.type == 'mailbox') XprsArchive.instance.recordMailboxDecl(p);

    // ── Gossip feeds (36.9.4) + the 36.8.1 release trigger ──────────────
    // Cheap checks first (performance.md 4.2): everything below is a map
    // lookup or an indexed upsert; the one curve operation is gated on a
    // hears: list actually being present AND the signer's key being known.
    if (!p.has('via')) {
      final gb = _archiveBearer(bearer);
      XprsGossip.instance.noteDirect(from, self, bearer: gb);
      try {
        onDirectHeard?.call(from, gb);
      } catch (e) {
        LogService.instance.add('XPRS: direct-heard hook failed: $e');
      }
      if (p.type == 'observation' &&
          p.has('hears') &&
          XprsGossip.instance.wouldAcceptHears(from)) {
        final hears = (p['hears'] ?? '')
            .split(',')
            .map((c) => c.trim().toUpperCase())
            .where((c) => c.isNotEmpty)
            .toList();
        if (hears.isNotEmpty) {
          // The verify is the expensive step (a curve op, on this isolate)
          // and wouldAcceptHears above has already said the quota will admit
          // the claim — so it runs at most once per signer per quota window,
          // not once per beacon (performance.md 4.2).
          final verified = p.has('sig') &&
              xprsVerify(p, XprsArchive.instance.keyResolver?.call(from)) ==
                  XprsSigState.verified;
          XprsGossip.instance.noteHears(from, hears,
              link: p['link'] ?? gb, verified: verified);
        }
      }
    }

    // `t:identity` (section 9.3) is a station publishing the key its callsign
    // signs with, and it is the only way to LEARN that binding off the air.
    // Without it every signature from a station we have never met stays
    // `unverified` — not because it is bad, but because nothing here could
    // check it.
    if (p.type == 'identity') _bindIdentity(from, p);

    // The preference governs the INDEXER — other people's traffic. A packet
    // addressed to us is our own mail and is kept either way.
    final forUs = _base(p['d'] ?? '').isNotEmpty &&
        _base(p['d'] ?? '') == _base(selfCallsign);
    if ((_archiveOn || forUs) && _worthKeeping(p, forUs: forUs)) {
      XprsArchive.instance
          .admit(p, bearer: _archiveBearer(bearer), rssi: rssi);
      try {
        onArchived?.call(from, xprsParseTs(p['ts']));
      } catch (_) {}
    }

    // And DELIVER it. Knowing a message is ours and only filing it is what
    // made a station's history replay invisible: the archive took it and
    // nothing else ever looked. This is the bearer-agnostic place for that —
    // every surface reaches this funnel, so BLE 0x58, BLE 0x41, LAN UDP and
    // TCP are all covered by one call instead of a tap per transport.
    //
    // Cheap checks first: this runs for every inbound packet, and the
    // verification behind it is a curve operation (docs/performance.md 4.2).
    if (forUs && onDeliver != null && p.type == 'message') {
      try {
        onDeliver!(p, _archiveBearer(bearer));
      } catch (e) {
        LogService.instance.add('XPRS: delivery failed: $e');
      }
    }

    try {
      onCommand?.call(p,
          selfBase: _base(selfCallsign), bearer: _archiveBearer(bearer));
    } catch (e) {
      LogService.instance.add('XPRS: command handling failed: $e');
    }

    if (p.type == 'result') {
      try {
        onResult?.call(p);
      } catch (e) {
        LogService.instance.add('XPRS: result handling failed: $e');
      }
    }
  }

  /// Identity packets verified in the current minute, and when that started.
  /// Verification is a curve operation and this runs on the receive path, so a
  /// station cannot be made to spend the afternoon checking invented callsigns.
  static int _idChecks = 0;
  static int _idWindowMs = 0;
  static const int _idChecksPerMinute = 20;

  /// Record a `k:npub…` against the callsign that signed for it.
  ///
  /// **Verified against the key it carries**, which is the whole point: a
  /// station saying "this is my key" must prove it holds that key, and it can,
  /// because the packet is signed with it. An unsigned or badly signed identity
  /// binds nothing.
  ///
  /// That still does not prove the CALLSIGN is theirs — nothing on an open
  /// bearer can — so the binding is [first-wins]: a later packet naming the
  /// same callsign with a different key is ignored. Overwriting would let
  /// anyone re-point a callsign by shouting last, and since the archive DROPS
  /// packets whose signature fails against the key it holds, that is enough to
  /// make a station's genuine traffic look forged and be thrown away.
  static void _bindIdentity(String callsign, XprsPacket p) {
    final hook = onIdentity;
    final npub = p['k'];
    if (hook == null || npub == null || !npub.startsWith('npub1')) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _idWindowMs > 60000) {
      _idWindowMs = now;
      _idChecks = 0;
    }
    if (++_idChecks > _idChecksPerMinute) return;

    try {
      final hex = NostrCrypto.decodeNpub(npub);
      if (hex.length != 64) return;
      final pub = Uint8List.fromList(HEX.decode(hex));
      if (xprsVerify(p, pub) != XprsSigState.verified) {
        LogService.instance
            .add('XPRS: identity from $callsign does not sign for its own key');
        return;
      }
      hook(callsign, hex);
    } catch (_) {
      // A malformed npub is a malformed field, and section 4 says skip it.
    }
  }

  /// One of OUR wires, at the moment it was put on a bearer — or attempted and
  /// carried by none, in which case [bearer] is `none`. Archived with `own=1`
  /// so a `cmd:history` asked of the author can replay the author, which is
  /// the whole reason a station keeps its own log (section 36.5).
  ///
  /// **This is the single recorder for outbound traffic, and it is not
  /// optional.** It ignores the `xprsArchive` preference on purpose: that
  /// preference governs whether this station indexes OTHER people's traffic,
  /// where the storage cost and the choice actually live. Switching the
  /// indexer off must not stop a station keeping its own log.
  ///
  /// Every transmit primitive calls this. A new bearer that does not is a
  /// bearer whose traffic silently leaves no trace.
  static void own(String wire, {required String bearer}) {
    final p = XprsPacket.parse(wire);
    if (p == null) return;
    // Our own log stays complete for everything a `cmd:history` asked of US
    // could replay -- section 36.5, and the reason this ignores the indexer
    // preference. Our own PRESENCE is the exception: nobody has ever asked a
    // phone to replay its own beacons, and on the bench they were 139 of the
    // newest 200 rows in this device's archive.
    if (!_worthKeeping(p, forUs: false)) return;
    XprsArchive.instance
        .admit(p, bearer: _archiveBearer(bearer), own: true);
  }

  /// An XPRS datagram off the Reticulum 'xprs' tag. Never shown as a sighting
  /// (the monitor's no-internet invariant is structural, and this lane does
  /// not call it), and archived only under the declaration rule above.
  ///
  /// [bearer] is where the datagram actually travelled, which the Reticulum
  /// node knows from the interface it arrived on: a phone on the same LAN, a
  /// board over Bluetooth or LoRa, or `rns` when it genuinely came off a hub.
  /// It is the ARCHIVE label only -- what a person is shown about a message.
  /// Every policy below still asks the Reticulum lane's questions (declaration
  /// gate, `link:`-decides gossip, the command lane's reply route), because
  /// this lane's rules are about how the packet was HANDED OVER, not about
  /// which radio carried it.
  static void reticulum(String from, Uint8List payload,
      {String bearer = 'rns'}) {
    final p = XprsPacket.parse(utf8.decode(payload, allowMalformed: true));
    if (p == null) return;
    final self = _base(
        XprsArchive.instance.selfCallsign.isEmpty
            ? ''
            : XprsArchive.instance.selfCallsign);
    final fromC = _base(p['f'] ?? '');
    if (fromC.isEmpty || (self.isNotEmpty && fromC == self)) return;

    // The hub lane serves too (docs/XPRS.md 36.0: the archiver role does not
    // change with the bearer). Commands and results route to the same hooks
    // every radio feeds -- until they did, a cmd:history that crossed the
    // internet was at best archived and never answered, and the server's
    // "refuse rns" counter guarded a path nothing reached. The DECLARATION
    // gate below is deliberately untouched: it governs what this station
    // spools off the internet, not what it will say.
    if (self.isNotEmpty) {
      if (p.type == 'command') {
        try {
          onCommand?.call(p, selfBase: self, bearer: 'rns');
        } catch (e) {
          LogService.instance.add('XPRS: rns command handling failed: $e');
        }
      } else if (p.type == 'result') {
        try {
          onResult?.call(p);
        } catch (e) {
          LogService.instance.add('XPRS: rns result handling failed: $e');
        }
      }
    }

    // `t:identity` binds callsign to key (9.3), and it is a publication a
    // gateway passes verbatim (36.1). Without this the internet lane could
    // never verify anything: a mailbox declaration arriving over the hubs
    // was refused for want of a key that had also arrived over the hubs --
    // two strangers meeting on the internet could not bootstrap at all.
    if (p.type == 'identity') _bindIdentity(fromC, p);

    // Gossip off the internet lane (36.9.4): a replayed observation arriving
    // over the hubs is exactly the "asker verifies and caches into its own
    // L3" step — the answer to a super-archiver ask lands HERE, not on any
    // radio, and without this feed the ask was paid for and the answer
    // discarded. noteHears' walls hold unchanged: an unverified claim feeds
    // nothing, and L2 stays radio-truth-only because the packet's own
    // `link:` decides — this lane's fallback is 'rns', which is not a
    // short-range bearer, so an internet arrival with no radio claim can
    // never write the durable layer.
    if (p.type == 'observation' &&
        p.has('hears') &&
        XprsGossip.instance.wouldAcceptHears(fromC)) {
      final hears = (p['hears'] ?? '')
          .split(',')
          .map((c) => c.trim().toUpperCase())
          .where((c) => c.isNotEmpty)
          .toList();
      if (hears.isNotEmpty) {
        // Quota peek first, verify second — same order as the radio lane,
        // same reason (performance.md 4.2).
        final verified = p.has('sig') &&
            xprsVerify(p, XprsArchive.instance.keyResolver?.call(fromC)) ==
                XprsSigState.verified;
        XprsGossip.instance
            .noteHears(fromC, hears, link: p['link'] ?? 'rns', verified: verified);
      }
    }

    if (p.type == 'mailbox') {
      // Acting on it requires a verified signature (13.12); recordMailboxDecl
      // enforces that. A declaration naming us is itself worth keeping.
      if (XprsArchive.instance.recordMailboxDecl(p) && _archiveOn) {
        XprsArchive.instance.admit(p, bearer: bearer);
      }
      return;
    }
    final toC = _base(p['d'] ?? '');

    // Addressed to us: our own mail, kept with no declaration from anyone and
    // regardless of the indexer preference. The declaration rule below exists
    // to stop this station spooling the whole Reticulum lane on other
    // people's behalf; it was never meant to refuse our own post.
    if (toC.isNotEmpty && toC == self) {
      XprsArchive.instance.admit(p, bearer: bearer);
      return;
    }

    // Mail for a third party: the custody question, not the archive one.
    // The park-or-not decision (budgets, quotas, 31.3) belongs to the
    // receiver; this lane only reports that mail arrived seeking a holder.
    if (p.type == 'message' && toC.isNotEmpty && toC != self) {
      try {
        onCarry?.call(p.encode(), toC);
      } catch (e) {
        LogService.instance.add('XPRS: rns carry hook failed: $e');
      }
    }

    if (!_archiveOn) return;

    // A super-archiver keeps the chatter (36.12.1): observations and
    // identities are the wires its bulk-gossip replays serve, they are
    // publications a gateway passes verbatim (36.1), and on a super they
    // mostly ARRIVE over this lane — the boards dial in over Reticulum.
    // The declaration rule below guards against spooling other people's
    // MAIL off the internet; presence is not mail, and a super that
    // refused it could never answer `kind:observation` about anyone.
    final superKeeps = (PreferencesService.instanceSync?.xprsSuperArchiver ??
            false) &&
        (p.type == 'observation' || p.type == 'identity' || p.type == 'service');

    // A status is this network's public post (section 27), and a reaction is
    // how it earns its place (6.5). Both are PUBLICATIONS -- meant to be
    // passed on and read by strangers -- so the declaration rule, which
    // exists to stop this station spooling other people's MAIL off the
    // internet, does not apply to them. Without this the launcher only ever
    // saw what the radio heard, and a station one hop away over a hub was
    // invisible.
    // What a publication IS on this lane: something written for everybody.
    // A status (27) and the reaction that judges it (6.5) always are, and so
    // is a `t:message` with NO `d:` -- that is the broadcast chat every
    // station is meant to read, the Global chat room in the chat wapp. The
    // declaration rule exists to stop this station spooling other people's
    // MAIL off the internet, and mail is precisely the case that HAS a `d:`;
    // it is still gated, still routed through custody. Without this, two
    // stations on different internet connections could see each other's
    // presence and never each other's words.
    final publication = p.type == 'status' ||
        p.type == 'reaction' ||
        (p.type == 'message' && toC.isEmpty);

    final admitted = superKeeps ||
        publication ||
        XprsArchive.instance.hasActiveDecl(fromC) ||
        (toC.isNotEmpty && XprsArchive.instance.hasActiveDecl(toC));
    if (!admitted) {
      refusedRns++;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastRefuseLogMs > 60000) {
        _lastRefuseLogMs = now;
        LogService.instance.add(
            'XPRS archive: rns refused (no declaration from $fromC — '
            '$refusedRns refused so far)');
      }
      return;
    }
    XprsArchive.instance.admit(p, bearer: bearer);
    try {
      onArchived?.call(fromC, xprsParseTs(p['ts']));
    } catch (_) {}
  }
}
