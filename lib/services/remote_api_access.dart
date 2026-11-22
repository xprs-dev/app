/*
 * remote_api_access — who may call the remote-control API.
 *
 * The API can launch wapps, send as the user and install updates, so by
 * default it listens on this device only (a bench tool reaches it over
 * `adb forward`). Its owner may open it to the local network, to let a
 * computer on the same Wi-Fi drive a phone that is not on a cable; then a
 * caller must be on a private address AND carry the key the Developer page
 * shows, and a web page is refused either way (a browser marks its requests
 * with Origin or Sec-Fetch headers).
 *
 * Pure, so the rule is tested without a socket.
 */
library;

import 'dart:math';

/// A key for the local network: 20 characters, no look-alikes.
String newRemoteApiKey([Random? rng]) {
  const abc = 'abcdefghjkmnpqrstuvwxyz23456789';
  final r = rng ?? Random.secure();
  return [for (var i = 0; i < 20; i++) abc[r.nextInt(abc.length)]].join();
}

/// A private or link-local IPv4 address, as text.
bool isPrivateLanAddress(String ip) {
  final p = ip.split('.');
  if (p.length != 4) return false;
  final a = int.tryParse(p[0]) ?? -1, b = int.tryParse(p[1]) ?? -1;
  return a == 10 ||
      (a == 192 && b == 168) ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 169 && b == 254);
}

bool _same(String a, String b) {
  if (a.length != b.length) return false;
  var d = 0;
  for (var i = 0; i < a.length; i++) {
    d |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return d == 0;
}

/// May this request in? [peer] is the address it came from, [host] its Host
/// header without the port, [browser] whether it carries a browser's marks,
/// [given] the key it sent.
bool remoteApiAdmits({
  required String peer,
  required String? host,
  required bool browser,
  required bool lanOpen,
  required String key,
  required String given,
}) {
  if (browser) return false;
  final local = peer == '127.0.0.1' || peer == '::1';
  if (local) {
    return host == null ||
        host == '127.0.0.1' ||
        host == 'localhost' ||
        host == '::1' ||
        host == '[::1]';
  }
  if (!lanOpen || key.length < 16) return false;
  return isPrivateLanAddress(peer) && _same(key, given);
}

/// The whole address to hand somebody, one per network this device is on.
List<String> remoteApiUrls(List<String> addresses, int port, String key) =>
    [for (final a in addresses) 'http://$a:$port/api/status?key=$key'];
