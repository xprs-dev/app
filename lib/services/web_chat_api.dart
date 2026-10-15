/*
 * The station API a visitor's browser gets from this phone: just enough of
 * spec/API-HTTP.md for the web chat page (the sibling repo `webchat`), and
 * nothing else.
 *
 * It is NOT the remote API. That one is loopback-only, off by default, and
 * switches bearers and administers groups; this one faces whoever joined the
 * hotspot, so it is an allowlist of three reads and one write, with the rules
 * that makes safe on a phone that holds its owner's mail:
 *
 *   GET  /api/services      what this host offers: which tabs, and `app`
 *   GET  /api/xprs/history  PUBLIC rows only (no `d:`, no mail, no group)
 *   POST /api/xprs/send     a finished wire the visitor signed in the browser
 *
 * The browser holds the key and signs; this host never sees a private key and
 * never signs for the visitor. A wire is refused unless it is signed, is not
 * written as this station, is one of the few types a visitor may post, and
 * fits the packet. What it accepts goes through the core's one receive door
 * (the callbacks below) and is aired verbatim, so the rest of the mesh sees
 * the visitor's own packet, with the visitor's own signature.
 *
 * Pure over its callbacks (no sockets, no singletons) so every rule is tested
 * without a phone; ShareAppService is the socket half.
 */
import 'dart:typed_data';

import 'xprs/xprs_archive.dart' show XprsArchive;
import 'xprs/xprs_id.dart';
import 'xprs/xprs_packet.dart';
import 'xprs/xprs_sig.dart';
import 'xprs/xprs_vocab.dart' show xprsParseTs;

/// One answer: a status and a JSON body.
class WebChatReply {
  final int status;
  final Map<String, dynamic> json;
  const WebChatReply(this.status, this.json);
}

class WebChatApi {
  /// Rows of [types] that are PUBLIC (undirected), newest first.
  final List<Map<String, dynamic>> Function(
      {int? sinceMs,
      int? untilMs,
      required List<String> types,
      String? from,
      required int limit}) publicRows;

  /// How many public rows the archive holds (the page's "N packets held").
  final int Function(List<String> types) held;

  /// A visitor's wire, to the core's receive door as heard on the hotspot.
  final void Function(String wire) receive;

  /// The same wire, aired verbatim on the other bearers.
  final Future<void> Function(String wire) air;

  /// Whether the core would air this packet (a closed group this station
  /// does not belong to is not ours to post into).
  final bool Function(XprsPacket p) mayAir;

  /// This station's own callsign, which a visitor must never write as `f:`.
  final String Function() selfCallsign;

  /// The key a callsign is bound to, when this station has heard one.
  final Uint8List? Function(String baseCallsign) keyOf;

  /// The path of the download page, or null when this copy cannot be handed
  /// on (an app store install in pieces).
  final String? Function() appPath;

  final DateTime Function() now;

  WebChatApi({
    required this.publicRows,
    required this.held,
    required this.receive,
    required this.air,
    required this.mayAir,
    required this.selfCallsign,
    required this.keyOf,
    required this.appPath,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  /// What a visitor may read: conversation, not machinery.
  static const Set<String> readable = {
    'message', 'reaction', 'status', 'info', 'warning', 'event', 'blog', 'sos',
  };

  /// What a visitor may post. An identity so others can verify their
  /// signature; a command or a group act is never a visitor's to send.
  static const Set<String> postable = {
    'message', 'status', 'reaction', 'identity',
  };

  static const int maxLimit = 200;
  static const int defaultLimit = 30;

  /// One visitor, one address: no more than a few in a second and thirty in
  /// a minute. A walk-up page is not a bulk lane.
  static const int burst = 5;
  static const int perMinute = 30;
  final Map<String, List<int>> _sent = {};

  /// Distinct visitors that have talked to this host since it started, and
  /// who to tell when another arrives (the Share screen's count).
  final Set<String> visitors = {};
  void Function(int count)? onVisitors;

  Future<WebChatReply> handle(
      String method, String path, Map<String, String> query, String body,
      {String peer = ''}) async {
    if (peer.isNotEmpty && visitors.add(peer)) onVisitors?.call(visitors.length);
    if (method == 'GET' && path == '/api/services') return _services();
    if (method == 'GET' && path == '/api/xprs/history') return _history(query);
    if (path == '/api/xprs/send' && (method == 'POST' || method == 'GET')) {
      // GET with ?wire= is the fallback the page uses when a captive WebView
      // refuses a POST (spec/API-HTTP.md); it is the same send.
      final wire = method == 'GET' ? (query['wire'] ?? '') : _wireOf(body);
      return _send(wire, peer);
    }
    return const WebChatReply(404, {'ok': false, 'error': 'not here'});
  }

  WebChatReply _services() {
    final app = appPath();
    return WebChatReply(200, {
      'ok': true,
      'features': <String, bool>{},
      'serve': <String>[],
      'page': {
        'tabs': ['chat', 'traffic'],
        'config': false,
        if (app != null) 'app': app,
      },
    });
  }

  /// `since`/`until` are epoch seconds or the packet timestamp form.
  static int? _when(String? v) {
    if (v == null || v.isEmpty) return null;
    final secs = int.tryParse(v);
    if (secs != null) return secs * 1000;
    return xprsParseTs(v);
  }

  WebChatReply _history(Map<String, String> q) {
    var types = <String>[
      for (final t in (q['kind'] ?? q['only'] ?? '').split(','))
        if (readable.contains(t.trim())) t.trim(),
    ];
    // Asked for nothing readable, or for nothing in particular: conversation.
    if (types.isEmpty) types = readable.toList();
    final limit =
        (int.tryParse(q['limit'] ?? '') ?? defaultLimit).clamp(1, maxLimit);
    var rows = publicRows(
      sinceMs: _when(q['since']),
      untilMs: _when(q['until']),
      types: types,
      from: (q['call'] ?? '').trim().isEmpty ? null : q['call']!.trim(),
      limit: limit,
    );
    final dir = q['dir'];
    if (dir == 'in') rows = [for (final r in rows) if (r['own'] != true) r];
    if (dir == 'out') rows = [for (final r in rows) if (r['own'] == true) r];
    return WebChatReply(200, {
      'ok': true,
      'count': rows.length,
      'held': held(types),
      'time': 'synced',
      'rows': rows,
    });
  }

  static String _wireOf(String body) {
    final b = body.trim();
    if (b.startsWith('{')) {
      final m = RegExp(r'"wire"\s*:\s*"((?:[^"\\]|\\.)*)"').firstMatch(b);
      if (m == null) return '';
      return m[1]!
          .replaceAll(r'\"', '"')
          .replaceAll(r'\\', r'\')
          .replaceAll(r'\n', ' ');
    }
    // A form body, `wire=…`, or the packet itself.
    if (b.startsWith('wire=')) {
      return Uri.decodeQueryComponent(b.substring(5));
    }
    return b;
  }

  bool _allowed(String peer) {
    final t = now().millisecondsSinceEpoch;
    final log = _sent.putIfAbsent(peer, () => <int>[]);
    log.removeWhere((x) => t - x > 60000);
    if (log.length >= perMinute) return false;
    final lastSecond = log.where((x) => t - x < 1000).length;
    if (lastSecond >= burst) return false;
    log.add(t);
    return true;
  }

  Future<WebChatReply> _send(String wire, String peer) async {
    WebChatReply no(int status, String why) =>
        WebChatReply(status, {'ok': false, 'error': why});
    final p = XprsPacket.parse(wire.trim());
    if (p == null || !p.fits) return no(400, 'malformed');
    if (!postable.contains(p.type)) return no(403, 'not for a visitor to send');
    final from = (p['f'] ?? '').trim().toUpperCase();
    if (from.isEmpty) return no(400, 'no f:');
    // Never as this station: the publisher would sign an unsigned wire that
    // speaks as the phone, and a visitor would be writing in its owner's name.
    final me = selfCallsign().trim().toUpperCase();
    String base(String c) => c.split('-').first;
    if (me.isNotEmpty && base(from) == base(me)) {
      return no(403, 'not as this station');
    }
    if (!p.has('sig')) return no(400, 'unsigned');
    // When this station already knows the key that callsign is bound to, the
    // signature must hold; with none known it is relayed as unverified, which
    // is what every receiver will conclude for themselves.
    final state = xprsVerify(p, keyOf(base(from)));
    if (state == XprsSigState.forged) return no(400, 'forged');
    if (!mayAir(p)) return no(403, 'not a member of that group');
    if (!_allowed(peer)) return no(429, 'slow down');
    final w = p.encode();
    receive(w);
    await air(w);
    return WebChatReply(200, {'ok': true, 'id': _idOf(p), 'wire': w});
  }

  String _idOf(XprsPacket p) => xprsIdentifier(p);
}

/// The archive-backed [WebChatApi.publicRows]: undirected rows of [types]
/// only. A mailbox, a group's traffic and a direct message all carry a `d:`,
/// so `to: ['']` (the undirected shelf) leaves them out by construction.
List<Map<String, dynamic>> archivePublicRows(
    {int? sinceMs,
    int? untilMs,
    required List<String> types,
    String? from,
    required int limit}) {
  return XprsArchive.instance.query(
    sinceMs: sinceMs,
    untilMs: untilMs,
    types: types,
    to: const [''],
    from: from,
    limit: limit,
  );
}
