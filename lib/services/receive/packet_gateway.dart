/*
 * packet_gateway — the one door every received mesh packet comes through.
 *
 * A received frame used to be demuxed wherever it happened to land. The same
 * four-line XBLOB/MSP/parcel cascade was written out at four GATT call sites,
 * `XprsPacket.parse` was repeated at five more, and each copy decided on its
 * own what to do when the parse returned null. That is how the shortcuts got
 * in: nothing was refused, nothing errored, and each new lane only had to
 * forget one call to deliver nothing at all.
 *
 * docs/architecture.md already says a wapp "is not told which radio carried
 * the message" and names transport logic in a wapp as the first recurring
 * mistake. This file is the other half of that rule: the core decides what a
 * frame IS in exactly one place, and every transport becomes a byte source.
 *
 * ── What comes through here ──────────────────────────────────────────────
 * The mesh/message-bearing lanes, whatever carried them:
 *   XPRS text wires · legacy compact frames · MSP session frames ·
 *   XBLOB blocks · BLE parcels
 * over BLE5 advertising, GATT (both roles, both stacks), LAN, TCP and
 * Reticulum. An RNS-tagged GATT payload does NOT come through here -- it is
 * stripped and handed to the Reticulum interface before this point
 * (`ble_service_io`), because Reticulum owns its own framing. This header
 * claimed otherwise until an audit checked it. LoRa and ESPNow have no receive path on this device today --
 * both are bearer LABELS only (`kBearers`, `hal_lora_recv` is a stub) -- so a
 * packet of theirs arrives relayed by a station and enters as one of the
 * above. The bearer argument is ready for them the day a radio ships.
 *
 * ── What deliberately does NOT ───────────────────────────────────────────
 * Not every byte the app ingests is a packet. DHT records, I2P tunnel cells,
 * torrent pieces, HTTP media uploads, deep links, the NOSTR hero feed,
 * WiFi-Direct negotiation and the binary mesh beacon carry no message and
 * have their own paths. Routing them through here would build a god-object
 * and would not make one message more reliable. If you are about to add a
 * case for one of them, that is the signal it belongs somewhere else.
 *
 * ── The rule ─────────────────────────────────────────────────────────────
 * A transport hands over bytes and a label. It does not parse, it does not
 * decide, and it does not reach past this file to `XprsIngest`, `MeshCourier`
 * or the inbox. `tool/arch_guard.dart` (`one-receive-door`) fails the build
 * when it does, because a rule nobody checks is a rule that lasts one sprint.
 */
import 'dart:convert';
import 'dart:typed_data';

import '../log_service.dart';
import '../mesh/mesh_custody.dart';
import '../mesh/mesh_service.dart';
import '../mesh/mesh_session.dart' show mspIsFrame;
import '../mesh/xblob_service.dart';
import '../xprs/xprs_ingest.dart';
import 'wapp_delivery.dart';
import '../xprs/xprs_packet.dart';

/// How the bytes reached us. Not the bearer — the shape of the arrival.
enum RxLane {
  /// A connectionless broadcast: BLE5 extended advertising, LAN UDP.
  advert,

  /// A connection: GATT (either role), TCP.
  session,

  /// A reassembled or routed payload handed up by a lower layer.
  datagram,
}

/// What the gateway made of a frame. Returned so a caller can act on the
/// decision without repeating it — the parcel lane is the one that must.
enum RxVerdict {
  /// Taken by the bulk file transfer session.
  blob,

  /// Taken by an MSP custody/session exchange.
  session,

  /// An XPRS packet; handed to the funnel.
  xprs,

  /// A legacy compact frame; handed to the custody tap.
  compact,

  /// None of the above on a connection — it belongs to the parcel
  /// reassembler, which is a codec and not a decision. The caller feeds its
  /// queue and the reassembled result comes back through [receive].
  parcel,

  /// Nothing here. Counted, not logged per frame.
  ignored,
}

class PacketGateway {
  PacketGateway._();
  static final PacketGateway instance = PacketGateway._();

  /// Counters, because the receive path was unobservable and that is how
  /// three rounds of fixes needed a screenshot to evaluate. One line a
  /// minute from the caller's own telemetry beats a line per frame
  /// (docs/performance.md 8.10).
  static int blobs = 0;
  static int sessions = 0;
  static int xprsFrames = 0;
  static int compactFrames = 0;
  static int parcels = 0;
  static int ignored = 0;

  /// Set by tests to observe every arrival without standing up a radio.
  /// One slot, like the funnel's own hooks.
  static void Function(String bearer, RxLane lane, RxVerdict verdict)? onFrame;

  /// A parsed XPRS packet, after the funnel has seen it.
  ///
  /// Set by MeshService for §13.1 repeating and beacon handling. That is the
  /// "what do we do with it next" half of receiving -- bridging and
  /// re-broadcasting are core decisions, and they belong on this side of the
  /// door rather than inside whichever radio happened to hear the packet.
  static void Function(
          XprsPacket p, String bearer, String peer, int rssi, String wire)?
      onXprsPacket;

  static void debugReset() {
    blobs = sessions = xprsFrames = compactFrames = parcels = ignored = 0;
    onFrame = null;
    onXprsPacket = null;
  }

  /// Take a received frame from any bearer.
  ///
  /// [bearer] is a word from `kBearers` (`ble`, `lan`, `rns`, …) — what a
  /// radio person would call it, and what the monitor and archive file it
  /// under. [serverSide] matters only on a GATT session, where the same
  /// bytes mean different things to the two roles.
  RxVerdict receive(
    Uint8List bytes, {
    required String bearer,
    required RxLane lane,
    String peer = '',
    int rssi = 0,
    bool serverSide = false,
  }) {
    if (bytes.isEmpty) {
      ignored++;
      return _done(bearer, lane, RxVerdict.ignored);
    }

    // Order matters and is the order the four GATT call sites already used:
    // the binary lanes identify themselves by magic and are cheap to test,
    // so they are asked first and a text parse is never attempted on them.
    if (XblobService.instance.onFrame(bytes, serverSide: serverSide)) {
      blobs++;
      return _done(bearer, lane, RxVerdict.blob);
    }
    if (mspIsFrame(bytes) &&
        MeshSessionManager.instance.onFrame(bytes, serverSide: serverSide)) {
      sessions++;
      return _done(bearer, lane, RxVerdict.session);
    }

    // Text from here down. `allowMalformed` because a frame off the air is
    // not a promise of valid UTF-8, and a decode throw would take the whole
    // receive path down with it.
    final text = utf8.decode(bytes, allowMalformed: true);
    final p = XprsPacket.parse(text);
    if (p != null) {
      xprsFrames++;
      XprsIngest.heard(
        p,
        bearer: bearer,
        selfCallsign: MeshService.instance.tableCallsign,
        rssi: rssi,
      );
      try {
        onXprsPacket?.call(p, bearer, peer, rssi, text);
      } catch (e) {
        LogService.instance.add('Gateway: post-funnel handler threw: $e');
      }
      // Hand it to whichever wapps asked for this TYPE (§4.2). One topic per
      // `t:` value, so a feed wapp takes `t:status`, a poll wapp takes
      // `t:poll`, and neither has to see the other's traffic to find its own.
      try {
        final self = MeshService.instance.tableCallsign.trim().toUpperCase();
        final to = (p['d'] ?? '').trim().toUpperCase();
        WappDelivery.instance.deliverPacket(
          p,
          bearer: bearer,
          rssi: rssi,
          forUs: self.isNotEmpty && to == self,
        );
      } catch (e) {
        LogService.instance.add('Gateway: wapp delivery threw: $e');
      }
      return _done(bearer, lane, RxVerdict.xprs);
    }

    // A connection's leftovers belong to the parcel reassembler; a
    // broadcast's leftovers are the legacy compact frame, which only the
    // custody tap understands (overheard `?ACK`s purge, our own 1:1s feed
    // the have-bloom, other people's get parked — docs/mesh.md §6).
    if (lane == RxLane.session) {
      parcels++;
      return _done(bearer, lane, RxVerdict.parcel);
    }

    if (MeshFrameShape.looksCompact(bytes)) {
      compactFrames++;
      MeshCustodyDelegate.onAirFrame(bytes, outbound: false);
      return _done(bearer, lane, RxVerdict.compact);
    }

    ignored++;
    return _done(bearer, lane, RxVerdict.ignored);
  }

  /// The internet lane, which is a different rule and not a different door.
  ///
  /// Reticulum traffic is not bounded by radio range, so it is admission-gated
  /// (§13.12/§36.3) and never becomes a sighting — [XprsIngest.reticulum]
  /// owns that policy. It gets its own entry because the payload arrives as a
  /// wire with a source label rather than as bytes off a radio, not because
  /// the lane is allowed to route itself.
  void receiveInternet(String from, Uint8List payload,
      {String bearer = 'rns'}) {
    if (payload.isEmpty) return;
    xprsFrames++;
    XprsIngest.reticulum(from, payload, bearer: bearer);
    _done(bearer, RxLane.datagram, RxVerdict.xprs);
  }

  RxVerdict _done(String bearer, RxLane lane, RxVerdict v) {
    try {
      onFrame?.call(bearer, lane, v);
    } catch (e) {
      LogService.instance.add('Gateway: observer threw: $e');
    }
    return v;
  }
}

/// The one test that says whether bytes are the legacy compact frame.
///
/// Extracted so the gateway does not guess. `MeshFrame.parse` states the rule:
/// a compact frame always contains two `\x1F` separators and an XPRS packet
/// contains none. Previously the answer was "whatever `XprsPacket.parse`
/// rejected", which swept malformed and unknown frames into the custody tap
/// as though they were compact.
class MeshFrameShape {
  static const int _sep = 0x1F;

  static bool looksCompact(Uint8List bytes) {
    var seps = 0;
    for (final b in bytes) {
      if (b == _sep && ++seps >= 2) return true;
    }
    return false;
  }
}
