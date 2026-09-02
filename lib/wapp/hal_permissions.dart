import 'dart:convert';

/*
 * hal_permissions — which HAL surface a wapp is allowed to reach.
 *
 * Until this file existed, a wapp claimed a route by IMPORTING ITS SYMBOL.
 * `WappEngine._bindImports` offers every HAL import to every module and
 * swallows the failure when the module does not declare one:
 *
 *     for (final imp in allImports) {
 *       try { builder.addImports([imp]); } catch (_) { }
 *     }
 *
 * So the wasm's own import table was the access-control list, written by
 * whoever compiled the wasm. Any wapp that added `hal_lxmf_recv` received
 * every private message on the device -- `_lxmfInbox` has no recipient test --
 * and could raise its own notifications for them. That one is gone outright:
 * a permission is the wrong answer to a door that should not exist, and the
 * core delivers a message on the event bus instead. `hal_ble_scan_read` hands
 * out raw radio frames, with `from` and `rssi`, which is a transport opinion a
 * wapp is not supposed to have at all (docs/architecture.md §1) -- that one is
 * a copy taken after the receive door, so it is gated rather than removed.
 *
 * That is tolerable while every wapp in the tree is ours. It stops being
 * tolerable the moment somebody else's wapp can be installed, and designing
 * for that is the reason to do this before there are many of them rather than
 * after.
 *
 * ── The rule ─────────────────────────────────────────────────────────────
 * Anything that touches a communication path is GATED. A wapp reaches it only
 * if its `manifest.json` names the permission, which makes the claim explicit,
 * reviewable before install, and visible in one file rather than implied by a
 * symbol table nobody reads.
 *
 * Ungated, and deliberately so: the content APIs and the event bus. A wapp
 * hands the core CONTENT (`hal_xprs_send`) and is handed content back
 * (`hal_event_*`, `hal_msg_*`). Neither names a radio, so neither is a
 * transport. That pair is the whole intended surface, and a wapp built to it
 * needs no permission at all.
 */

/// A capability a wapp must declare in `manifest.json` to be granted.
class HalPermission {
  /// Read raw frames off a radio, and write frames to it.
  static const bleRaw = 'transport.ble.raw';

  /// Read and write Reticulum datagrams directly.
  static const rnsRaw = 'transport.rns.raw';

  /// Open arbitrary TCP sockets (the APRS-IS uplink is the only user).
  static const socket = 'transport.socket';

  /// Write to a named Reticulum destination over LXMF. NOT the shared inbox:
  /// that is no longer reachable from a wapp under any grant.
  static const lxmf = 'transport.lxmf';

  /// Send and receive NOSTR events and relay DMs.
  static const nostr = 'transport.nostr';

  /// The whole heard-traffic spool and the live monitor ring.
  static const spool = 'archive.read';

  static const all = [bleRaw, rnsRaw, socket, lxmf, nostr, spool];
}

/// Every gated import, by the name the wasm imports it under, mapped to the
/// permission that unlocks it. An import absent from this map is ungated.
///
/// Keyed on the import NAME rather than the Dart symbol, because that is what
/// a wasm module actually asks for and what a reviewer reads in a manifest.
const Map<String, String> kGatedImports = {
  // Radio, in both directions.
  'ble_scan_start': HalPermission.bleRaw,
  'ble_scan_stop': HalPermission.bleRaw,
  'ble_scan_read': HalPermission.bleRaw,
  'ble_advertise': HalPermission.bleRaw,
  'ble_advertise_stop': HalPermission.bleRaw,

  // Reticulum, raw.
  'rns_available': HalPermission.rnsRaw,
  'rns_recv': HalPermission.rnsRaw,
  'rns_broadcast': HalPermission.rnsRaw,
  'rns_send_to': HalPermission.rnsRaw,
  'rns_pull': HalPermission.rnsRaw,

  // Arbitrary sockets.
  'socket_open': HalPermission.socket,
  'socket_send': HalPermission.socket,
  'socket_recv': HalPermission.socket,
  'socket_close': HalPermission.socket,
  'socket_status': HalPermission.socket,

  // Addressing a named Reticulum destination directly. There is no `lxmf_recv`
  // any more — the shared inbox this permission was named for is not reachable
  // from a wapp at all now, in any grant. What is left is the send side, which
  // writes to ONE destination the wapp already names.
  'lxmf_send': HalPermission.lxmf,
  'lxmf_send2': HalPermission.lxmf,

  // NOSTR, including decrypted relay DMs.
  'nostr_event_recv': HalPermission.nostr,
  'nostr_subscribe': HalPermission.nostr,
  'nostr_unsubscribe': HalPermission.nostr,
  'nostr_post': HalPermission.nostr,
  'relay_dm_recv': HalPermission.nostr,
  'relay_dm_fetch': HalPermission.nostr,
  'relay_dm_send': HalPermission.nostr,

  // The spool and the live ring: everything this station ever heard.
  'xprs_history': HalPermission.spool,
  'xprs_traffic': HalPermission.spool,
  'xprs_stations': HalPermission.spool,
};

/// Whether [importName] may be bound for a wapp holding [granted].
///
/// Default is REFUSE for anything gated. A wapp that declares nothing gets
/// the content APIs and the event bus, which is the surface a well-behaved
/// wapp is supposed to be written against.
bool halImportAllowed(String importName, Set<String> granted) {
  final needs = kGatedImports[importName];
  if (needs == null) return true;
  return granted.contains(needs);
}

/// The permissions a wapp package declares, or an empty set.
///
/// Read from `manifest.json`'s `permissions` array. Anything unparseable is
/// an empty grant rather than a full one: a manifest that cannot be read is
/// not a manifest that consents.
Set<String> declaredPermissions(String? manifestJson) {
  if (manifestJson == null || manifestJson.isEmpty) return const {};
  try {
    final m = jsonDecode(manifestJson);
    if (m is! Map) return const {};
    final p = m['permissions'];
    if (p is! List) return const {};
    return p.whereType<String>().toSet();
  } catch (_) {
    return const {};
  }
}
