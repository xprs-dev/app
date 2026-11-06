/*
 * xprs_tcp — the plain-text half of the dual-protocol port.
 *
 * docs/XPRS.md section 24.4: port 4242 answers both Reticulum and XPRS on one
 * socket, told apart by the first byte. The TCP server does the telling; this
 * file is what a text connection gets. One packet per line, in and out, and
 * everything on the socket is an ordinary packet: a ping is answered with a
 * pong, a cmd:history with the section 25.2 replay served inline (no pacing —
 * the socket is the asker's own bandwidth).
 *
 * Where the peer IS decides what its packets are worth (24.4): a private or
 * loopback address is the LAN it looks like — bearer `lan`, on the air view,
 * archived like any local bearer. A public address travelled the internet, so
 * it gets exactly the Reticulum lane's treatment: no sighting, archived only
 * under the mailbox-declaration rule (36.3).
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../../util/nostr_crypto.dart';
import '../log_service.dart';
import '../mesh/mesh_service.dart';
import '../mesh/mesh_store.dart';
import 'xprs_archive.dart';
import 'xprs_history_server.dart';
import 'xprs_id.dart';
import 'xprs_mailbox.dart';
import '../receive/packet_gateway.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

/// The stations on an open text connection to THIS station right now, by
/// callsign (XPRS.md 13.0.2: "over an open connection the archiver
/// DELIVERS"). A peer is registered when a line it sent VERIFIES against the
/// key we hold for its `f:` — an unsigned claim on a socket would otherwise
/// collect somebody else's mail — and forgotten when the socket closes.
class XprsLinePeers {
  XprsLinePeers._();
  static final XprsLinePeers instance = XprsLinePeers._();

  final Map<String, _LinePeer> _peers = {};

  bool get any => _peers.isNotEmpty;

  bool isConnected(String callsign) =>
      _peers.containsKey(callsign.trim().toUpperCase());

  bool isConnectedOn(String callsign, String label) =>
      _peers[callsign.trim().toUpperCase()]?.label == label;

  /// One wire down the peer's socket; false when it is not connected.
  bool sendTo(String callsign, String wire) {
    final p = _peers[callsign.trim().toUpperCase()];
    if (p == null) return false;
    try {
      p.reply(wire);
      p.tx++;
      return true;
    } catch (_) {
      return false;
    }
  }

  void register(String callsign, String label, void Function(String) reply) {
    final c = callsign.trim().toUpperCase();
    if (c.isEmpty) return;
    _peers[c] = _LinePeer(c, label, reply, DateTime.now());
    LogService.instance.add('XPRS/tcp: $c is on $label (line peer)');
  }

  void unregister(String label) {
    _peers.removeWhere((_, p) => p.label == label);
  }

  List<Map<String, Object?>> get status => [
        for (final p in _peers.values)
          {
            'callsign': p.callsign,
            'label': p.label,
            'since': p.since.toIso8601String(),
            'tx': p.tx,
          }
      ];
}

class _LinePeer {
  _LinePeer(this.callsign, this.label, this.reply, this.since);
  final String callsign;
  final String label;
  final void Function(String) reply;
  final DateTime since;
  int tx = 0;
}

class XprsTcp {
  XprsTcp._();

  /// Lines longer than this are not XPRS (a packet is 250 bytes); a peer
  /// sending one is talking some other protocol at the wrong port.
  static const int _maxLine = 512;
  static const int _maxBuffered = 8192;

  static int served = 0;

  /// Attach a plain-text connection: returns the sink the TCP server feeds
  /// every chunk into. Matches RnsTcpServerInterface.onPlainText.
  static void Function(Uint8List data) attach(Socket socket, String label) {
    final local = _isLocal(socket.remoteAddress);
    final buf = StringBuffer();
    LogService.instance
        .add('XPRS/tcp: $label connected (${local ? "lan" : "internet"})');
    // The server destroys the socket on error or close and tells nobody;
    // `done` is what we can watch.
    unawaited(socket.done.then((_) => XprsLinePeers.instance.unregister(label),
        onError: (_) => XprsLinePeers.instance.unregister(label)));

    void handleLine(String line) {
      final wire = line.trim();
      if (wire.isEmpty) return;
      final p = XprsPacket.parse(wire);
      if (p == null) return;
      final selfCall = MeshService.instance.tableCallsign.trim();
      if (selfCall.isEmpty) return;
      final selfBase = NostrCrypto.bareCallsign(selfCall);

      final bytes = Uint8List.fromList(utf8.encode(wire));
      if (local) {
        // A LAN peer is a local bearer like any radio: sighting + spool.
        PacketGateway.instance
            .receive(bytes, bearer: 'lan', lane: RxLane.session, peer: label);
      } else {
        // The internet lane: declaration-gated, never a sighting.
        PacketGateway.instance.receiveInternet(label, bytes);
      }

      void reply(String w) {
        try {
          socket.add(utf8.encode('$w\n'));
        } catch (_) {}
      }

      // Who is on this socket (13.0.2). A signed line that verifies against
      // the key we hold for its author puts that author on the socket; from
      // then on what we hold for it, and what arrives for it, goes here.
      final from = NostrCrypto.bareCallsign(p['f'] ?? '');
      if (from.isNotEmpty &&
          from != selfBase &&
          p.has('sig') &&
          !XprsLinePeers.instance.isConnectedOn(from, label)) {
        final key = XprsArchive.instance.keyResolver?.call(from);
        if (xprsVerify(p, key) == XprsSigState.verified) {
          XprsLinePeers.instance.register(from, label, reply);
          // Deliver what we hold for it now, not at the next minute sweep.
          unawaited(XprsMailbox.instance.sweepHeld());
        }
      }

      // A reachability test is answered on the socket that asked (section 7's
      // vocabulary; no rssi: — a TCP byte has no signal strength to report).
      final to = NostrCrypto.bareCallsign(p['d'] ?? '');
      if (p.type == 'ping' && (to.isEmpty || to == selfBase)) {
        final from = (p['f'] ?? '').trim().toUpperCase();
        final now = DateTime.now().toUtc();
        String two(int n) => n.toString().padLeft(2, '0');
        var pong = XprsPacket.parse('t:pong f:$selfBase d:$from '
            'ts:${now.year}-${two(now.month)}-${two(now.day)}_'
            '${two(now.hour)}:${two(now.minute)}:${two(now.second)} '
            'r:${xprsIdentifier(p)}');
        if (pong != null) {
          final d = xprsProfileScalar();
          if (d != null) pong = xprsSign(pong, d);
          reply(pong.encode());
        }
        return;
      }

      // `q:mail only:X` (9.12.3): how much mail do we hold for X? Answered on
      // the socket, zero included — "nothing for you" and "did not hear
      // you" are different facts.
      if (p.type == 'request' &&
          (to.isEmpty || to == selfBase) &&
          (p['q'] ?? '').split(',').map((w) => w.trim()).contains('mail')) {
        final only = NostrCrypto.bareCallsign(p['only'] ?? from);
        if (only.isEmpty) return;
        final n = MeshStore.instance.ready
            ? MeshStore.instance.heldWiresFor(only).length
            : 0;
        var obs = XprsPacket.parse('t:observation f:$selfBase d:$from '
            'ts:${xprsNowTs()} s:mail mail:$n only:$only');
        if (obs != null) {
          final d = xprsProfileScalar();
          if (d != null) obs = xprsSign(obs, d);
          reply(obs.encode());
        }
        return;
      }

      // The whole reason this port serves text: catching up from the spool.
      // Served here, inline, and marked answered so the paced replay the
      // funnel would also start (the same ask reaches the history server
      // through the internet lane) does not send the page a second time.
      if ((p['cmd'] ?? '') == 'history') {
        XprsHistoryServer.instance.markAnswered(xprsIdentifier(p));
      }
      final page =
          XprsHistoryServer.instance.serveInline(p, selfBase: selfBase);
      if (page.isNotEmpty) {
        served++;
        for (final w in page) {
          reply(w);
        }
        LogService.instance.add(
            'XPRS/tcp: served ${page.length - 2 < 0 ? 0 : page.length - 2} '
            'packet(s) to $label');
      }
    }

    return (Uint8List data) {
      buf.write(utf8.decode(data, allowMalformed: true));
      if (buf.length > _maxBuffered) {
        // Not line-oriented text — stop pretending it is XPRS.
        try {
          socket.destroy();
        } catch (_) {}
        return;
      }
      var s = buf.toString();
      var nl = s.indexOf('\n');
      while (nl >= 0) {
        final line = s.substring(0, nl);
        s = s.substring(nl + 1);
        if (line.length <= _maxLine) handleLine(line);
        nl = s.indexOf('\n');
      }
      buf
        ..clear()
        ..write(s);
    };
  }

  static bool _isLocal(InternetAddress a) {
    if (a.isLoopback || a.isLinkLocal) return true;
    final b = a.rawAddress;
    if (a.type == InternetAddressType.IPv4 && b.length == 4) {
      if (b[0] == 10) return true;
      if (b[0] == 172 && b[1] >= 16 && b[1] <= 31) return true;
      if (b[0] == 192 && b[1] == 168) return true;
      return false;
    }
    // IPv6: unique-local fc00::/7 is the private range.
    return b.isNotEmpty && (b[0] & 0xFE) == 0xFC;
  }
}
