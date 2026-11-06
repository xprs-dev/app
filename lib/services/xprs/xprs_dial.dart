/*
 * xprs_dial — `dial:` as announced (XPRS.md 13.0.2): where an archiver
 * answers a TCP connection under the one-port rule. Pure, so the web build
 * and the tests can parse one without a socket in sight.
 */

/// Where an archiver said it answers (13.0.2 `dial:`): `host` or `host:port`.
class XprsDial {
  final String host;
  final int port;
  const XprsDial(this.host, this.port);

  /// Parses `dial:` as announced. Null for anything that is not a host.
  static XprsDial? parse(String? v) {
    final s = (v ?? '').trim();
    if (s.isEmpty || s.length > 253) return null;
    // IPv6 in brackets, host:port, or bare host.
    String host;
    var port = 4242;
    if (s.startsWith('[')) {
      final end = s.indexOf(']');
      if (end < 0) return null;
      host = s.substring(1, end);
      final rest = s.substring(end + 1);
      if (rest.isNotEmpty) {
        if (!rest.startsWith(':')) return null;
        port = int.tryParse(rest.substring(1)) ?? -1;
      }
    } else {
      final colon = s.lastIndexOf(':');
      if (colon > 0 && !s.substring(0, colon).contains(':')) {
        host = s.substring(0, colon);
        port = int.tryParse(s.substring(colon + 1)) ?? -1;
      } else {
        // A bare IPv6 literal is ambiguous with host:port; it is written
        // in brackets or not at all.
        if (s.contains(':')) return null;
        host = s;
      }
    }
    if (host.isEmpty || port < 1 || port > 65535) return null;
    if (!RegExp(r'^[A-Za-z0-9.\-:]+$').hasMatch(host)) return null;
    return XprsDial(host, port);
  }

  @override
  String toString() => port == 4242 ? host : '$host:$port';

  @override
  bool operator ==(Object other) =>
      other is XprsDial && other.host == host && other.port == port;
  @override
  int get hashCode => Object.hash(host, port);
}
