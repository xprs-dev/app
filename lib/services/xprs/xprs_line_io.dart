/*
 * xprs_line — the client half of the one-port rule (XPRS.md 13.4, 13.0.2).
 *
 * An archiver that announces `dial:` answers a TCP connection on 4242 with
 * XPRS as text, one packet per line. This is what a pocket device uses to
 * reach its archiver without being a node of the shared transport: no
 * announce, no flood, no forwarding for anybody, one idle socket. Everything
 * that crosses it is an ordinary packet: `q:mail`, `cmd:history since:`,
 * a deposit (`t:message d:`), a receipt, `t:mailbox`; and what comes back
 * is fed to the receive funnel exactly as the server feeds what it hears
 * on that port — the internet lane, declaration-gated, never a sighting.
 *
 * The socket is kept open on purpose (13.0.2: over an open connection the
 * archiver DELIVERS). Keeping an idle TCP socket costs a phone almost
 * nothing — it is how every push channel works — and what killed the radio
 * was the announce flood, which this lane does not carry. The kernel's
 * keepalive is set long (four minutes between probes while idle) so the
 * socket survives a NAT without waking the radio every minute.
 *
 * One client per archiver callsign; `XprsLineLane` (below) decides which
 * archivers are dialled and keeps the set small.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../log_service.dart';
import '../receive/packet_gateway.dart';
import 'xprs_dial.dart';
import 'xprs_packet.dart';

export 'xprs_dial.dart';

/// One text connection to one archiver.
class XprsLineClient {
  XprsLineClient({
    required this.callsign,
    required this.dial,
    this.log,
  });

  final String callsign;
  final XprsDial dial;
  final void Function(String)? log;

  /// The label the funnel sees the peer under; what `/api/status` shows.
  String get label => 'line:$callsign';

  Socket? _sock;
  StreamSubscription<Uint8List>? _sub;
  final StringBuffer _buf = StringBuffer();
  bool _wanted = false;
  bool _connecting = false;
  Timer? _retry;
  int _failures = 0;
  DateTime? _connectedAt;
  DateTime? _lastRxAt;
  int _rxPackets = 0, _txPackets = 0;

  static const int _maxLine = 512;
  static const int _maxBuffered = 8192;
  static const Duration _connectTimeout = Duration(seconds: 12);
  static const Duration _retryFloor = Duration(seconds: 15);
  static const Duration _retryCeiling = Duration(minutes: 10);

  bool get connected => _sock != null;
  bool get wanted => _wanted;
  DateTime? get connectedAt => _connectedAt;
  DateTime? get lastRxAt => _lastRxAt;

  /// Called for every packet that comes back, after the funnel has had it.
  void Function(XprsPacket p, String wire)? onPacket;

  /// Called when the socket comes up (after a dial or a reconnect): the
  /// moment to ask `q:mail` and open the catch-up window.
  void Function()? onUp;

  /// Called when the socket goes down, with why.
  void Function(String why)? onDown;

  /// Keep a connection to this archiver until [close]. Idempotent.
  Future<void> open() async {
    _wanted = true;
    await _connect();
  }

  /// Let the connection go and stop retrying.
  void close([String why = 'closed']) {
    _wanted = false;
    _retry?.cancel();
    _retry = null;
    _drop(why, retry: false);
  }

  /// One packet, as a line. False when there is no socket (the caller's
  /// other lanes carry it); the lane does not queue, because a deposit that
  /// waits for a socket is what the mailbox already does better.
  bool send(String wire) {
    final s = _sock;
    if (s == null) return false;
    final w = wire.trim();
    if (w.isEmpty || w.length > _maxLine) return false;
    try {
      s.add(utf8.encode('$w\n'));
      _txPackets++;
      return true;
    } catch (e) {
      _drop('write failed: $e');
      return false;
    }
  }

  Future<void> _connect() async {
    if (!_wanted || _sock != null || _connecting) return;
    _connecting = true;
    try {
      final s = await Socket.connect(dial.host, dial.port,
          timeout: _connectTimeout);
      s.setOption(SocketOption.tcpNoDelay, true);
      _keepalive(s);
      // A write that the peer resets surfaces on `done`, which nobody awaits;
      // unobserved, it is an unhandled error on the zone. The listen's
      // onError below is where the drop is handled.
      unawaited(s.done.catchError((_) {}));
      _sock = s;
      _connectedAt = DateTime.now();
      _failures = 0;
      _buf.clear();
      _sub = s.listen(_onData, onError: (e) => _drop('socket error: $e'),
          onDone: () => _drop('peer closed'));
      log?.call('XPRS/line: $callsign up at $dial');
      onUp?.call();
    } catch (e) {
      _failures++;
      log?.call('XPRS/line: $callsign at $dial failed ($e), '
          'retry in ${_retryIn().inSeconds}s');
      _armRetry();
    } finally {
      _connecting = false;
    }
  }

  Duration _retryIn() {
    final n = _failures.clamp(0, 6);
    final d = _retryFloor * (1 << n);
    return d > _retryCeiling ? _retryCeiling : d;
  }

  void _armRetry() {
    if (!_wanted) return;
    _retry?.cancel();
    _retry = Timer(_retryIn(), () {
      _retry = null;
      unawaited(_connect());
    });
  }

  void _drop(String why, {bool retry = true}) {
    final s = _sock;
    if (s == null) return;
    _sock = null;
    _sub?.cancel();
    _sub = null;
    try {
      s.destroy();
    } catch (_) {}
    log?.call('XPRS/line: $callsign down ($why)');
    onDown?.call(why);
    if (retry && _wanted) {
      _failures++;
      _armRetry();
    }
  }

  void _onData(Uint8List data) {
    _buf.write(utf8.decode(data, allowMalformed: true));
    if (_buf.length > _maxBuffered) {
      _drop('not line-oriented text');
      return;
    }
    var s = _buf.toString();
    var nl = s.indexOf('\n');
    while (nl >= 0) {
      final line = s.substring(0, nl);
      s = s.substring(nl + 1);
      if (line.length <= _maxLine) _onLine(line);
      nl = s.indexOf('\n');
    }
    _buf
      ..clear()
      ..write(s);
  }

  void _onLine(String line) {
    final wire = line.trim();
    if (wire.isEmpty) return;
    final p = XprsPacket.parse(wire);
    if (p == null) return;
    _lastRxAt = DateTime.now();
    _rxPackets++;
    // The internet lane: declaration-gated, never a sighting — the same door
    // the server uses for a connection from a public address (xprs_tcp.dart).
    PacketGateway.instance
        .receiveInternet(label, Uint8List.fromList(utf8.encode(wire)));
    onPacket?.call(p, wire);
  }

  /// Linux/Android socket-option numbers (stable in the kernel ABI). Long
  /// idle on purpose: a probe every minute would wake the radio every
  /// minute, and a NAT keeps a TCP mapping far longer than four.
  static void _keepalive(Socket s) {
    const solSocket = 1, soKeepalive = 9;
    const ipprotoTcp = 6;
    const tcpKeepidle = 4, tcpKeepintvl = 5, tcpKeepcnt = 6;
    void opt(int level, int option, int value) {
      try {
        s.setRawOption(RawSocketOption.fromInt(level, option, value));
      } catch (_) {}
    }

    opt(solSocket, soKeepalive, 1);
    if (Platform.isLinux || Platform.isAndroid) {
      opt(ipprotoTcp, tcpKeepidle, 240);
      opt(ipprotoTcp, tcpKeepintvl, 60);
      opt(ipprotoTcp, tcpKeepcnt, 3);
    }
  }

  Map<String, Object?> get status => {
        'callsign': callsign,
        'dial': dial.toString(),
        'connected': connected,
        'since': _connectedAt?.toIso8601String(),
        'lastRx': _lastRxAt?.toIso8601String(),
        'rx': _rxPackets,
        'tx': _txPackets,
        'failures': _failures,
      };
}

/// The lane: which archivers are dialled, and one socket per archiver.
///
/// Policy lives with the caller (the archiver choice, the power profile);
/// this keeps the set and the sockets. [wantAll] replaces the set: clients
/// for callsigns no longer named are closed, new ones opened, a changed
/// `dial:` re-dialled.
class XprsLineLane {
  XprsLineLane._();
  static final XprsLineLane instance = XprsLineLane._();

  final Map<String, XprsLineClient> _clients = {};
  void Function(XprsLineClient c)? onClientUp;

  Iterable<XprsLineClient> get clients => _clients.values;

  XprsLineClient? clientFor(String callsign) =>
      _clients[callsign.trim().toUpperCase()];

  /// Is [callsign] reachable on an open socket right now?
  bool connectedTo(String callsign) => clientFor(callsign)?.connected ?? false;

  /// Any open socket at all (the device's "internet through the archiver").
  bool get anyConnected => _clients.values.any((c) => c.connected);

  Future<void> wantAll(Map<String, XprsDial> want) async {
    final keep = <String>{};
    for (final e in want.entries) {
      final call = e.key.trim().toUpperCase();
      keep.add(call);
      final have = _clients[call];
      if (have != null && have.dial == e.value) continue;
      have?.close('re-dialled');
      final c = XprsLineClient(
        callsign: call,
        dial: e.value,
        log: (m) => LogService.instance.add(m),
      );
      c.onUp = () => onClientUp?.call(c);
      _clients[call] = c;
      unawaited(c.open());
    }
    for (final call in List.of(_clients.keys)) {
      if (keep.contains(call)) continue;
      _clients.remove(call)?.close('no longer chosen');
    }
  }

  /// Send one wire to [callsign] if it is on an open socket.
  bool sendTo(String callsign, String wire) =>
      clientFor(callsign)?.send(wire) ?? false;

  void closeAll([String why = 'closed']) {
    for (final c in List.of(_clients.values)) {
      c.close(why);
    }
    _clients.clear();
  }

  List<Map<String, Object?>> get status =>
      [for (final c in _clients.values) c.status];
}
