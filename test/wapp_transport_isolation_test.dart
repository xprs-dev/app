/*
 * NO WAPP TOUCHES A TRANSPORT. Asserted against the HOST's binding table, not
 * against a promise in a comment.
 *
 * This is the rule that kept being restated and kept not holding. The chat
 * wapp read raw BLE frames with their RSSI, put arbitrary bytes on that radio
 * under a subtype the core had to GUESS, ran a digipeater of its own, aired
 * frames under other stations' callsigns, opened a TCP socket to APRS-IS,
 * drove two NOSTR subscriptions, and named one Reticulum destination directly.
 *
 * Every one of those doors is deleted from the host. The point of this test is
 * that adding one back has to be deliberate: it fails the moment a binding
 * with a transport-shaped name reappears.
 */
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/hal_permissions.dart';

/// Every `WasmImport('hal', '<name>', …)` the engine binds.
Set<String> boundImports() {
  final src = File('lib/wapp/wapp_engine.dart').readAsStringSync();
  return RegExp(r"WasmImport\('hal',\s*'([a-z0-9_]+)'")
      .allMatches(src)
      .map((m) => m.group(1)!)
      .toSet();
}

void main() {
  test('the deleted transport doors are not bound by the host', () {
    // Each of these handed a wapp something no wapp may have: raw frames off a
    // radio with the advertiser's address and signal strength, the right to
    // put bytes on that radio, one named Reticulum destination, or the shared
    // inbox of everybody's correspondence.
    const gone = [
      'ble_scan_start', 'ble_scan_stop', 'ble_scan_read',
      'ble_advertise', 'ble_advertise_stop',
      'lxmf_recv', 'lxmf_send', 'lxmf_send2',
    ];
    final bound = boundImports();
    for (final name in gone) {
      expect(bound, isNot(contains(name)),
          reason: '$name is bound again — a wapp can reach a transport');
      expect(kGatedImports.containsKey(name), isFalse,
          reason: '$name is gated again; it should not exist to be gated');
    }
  });

  // A door does not have to be a HAL import to be a door. The mesh wapp posted
  // {"type":"rns.lxmf.send","pubkey":…} over the ungated content channel and
  // the host obligingly sent it to one Reticulum destination — `lxmf_send2`
  // rebuilt as a JSON string, past a test that only ever read the import table.
  test('the host handles no per-wapp transport action', () {
    final src = File('lib/wapp/wapp_page.dart').readAsStringSync();
    for (final action in ['rns.lxmf.send', 'ble.advertise', 'rns.send_to']) {
      expect(src.contains("'$action'"), isFalse,
          reason: "the host acts on '$action' — a wapp is choosing a lane "
              'without importing anything');
    }
  });

  test('the permission list names no door that no longer exists', () {
    final bound = boundImports();
    for (final imp in kGatedImports.keys) {
      expect(bound, contains(imp),
          reason: '$imp is gated but not bound — a permission for nothing');
    }
  });

  test('a wapp says what it wants said, and that needs no permission', () {
    final bound = boundImports();
    for (final imp in ['xprs_message', 'xprs_broadcast', 'xprs_send',
      'xprs_read', 'event_subscribe', 'event_recv', 'event_available']) {
      expect(bound, contains(imp), reason: '$imp must be available');
      expect(kGatedImports.containsKey(imp), isFalse,
          reason: '$imp is content, not a lane: it is not gated');
    }
  });

  test('the chat wapp imports no transport at all', () {
    // Parse the wasm IMPORT SECTION, not the file's bytes. Two substring
    // mistakes have already been made on this exact question: `event_recv`
    // matches inside `nostr_event_recv`, and `encrypt` matches the UI string
    // "Messages are private (encrypted)". The import table is the only place
    // that answers what a module can actually call.
    final wasm = File('../wapps/chat/app.wasm');
    if (!wasm.existsSync()) return; // wapps repo not checked out beside app
    final names = wasmHalImports(wasm.readAsBytesSync());

    expect(names, isNotEmpty, reason: 'parsed no imports at all');
    const forbidden = {
      'ble_scan_start', 'ble_scan_stop', 'ble_scan_read',
      'ble_advertise', 'ble_advertise_stop',
      'lxmf_recv', 'lxmf_send', 'lxmf_send2',
      'rns_recv', 'rns_available', 'rns_broadcast', 'rns_send_to', 'rns_pull',
      'socket_open', 'socket_send', 'socket_recv', 'socket_read_sync',
      'nostr_post', 'nostr_subscribe', 'nostr_event_recv', 'nostr_self',
      'relay_dm_send', 'relay_dm_recv', 'relay_dm_fetch', 'relay_resolve',
      // Its own crypto: doing it itself is how this wapp ended up with a
      // private encryption format AND a second signature scheme layered
      // inside `m:`, beside the 9.2 seal and 9.1 sig the core already ran.
      'encrypt', 'decrypt', 'verify',
    };
    expect(names.intersection(forbidden), isEmpty,
        reason: 'chat imports a transport or does its own crypto');

    for (final want in ['xprs_message', 'event_recv', 'event_subscribe']) {
      expect(names, contains(want), reason: 'chat should import $want');
    }
  });
}

/// The `hal.*` function names a wasm module imports.
Set<String> wasmHalImports(List<int> b) {
  int i = 8; // magic + version
  final out = <String>{};
  (int, int) leb(int p) {
    var r = 0, s = 0;
    while (true) {
      final x = b[p++];
      r |= (x & 0x7f) << s;
      if ((x & 0x80) == 0) return (r, p);
      s += 7;
    }
  }
  while (i < b.length) {
    final id = b[i++];
    var (size, p) = leb(i);
    i = p;
    final end = i + size;
    if (id == 2) {
      var (n, q) = leb(i);
      for (var k = 0; k < n; k++) {
        var (ml, r) = leb(q);
        final mod = String.fromCharCodes(b.sublist(r, r + ml));
        q = r + ml;
        var (nl, t) = leb(q);
        final nm = String.fromCharCodes(b.sublist(t, t + nl));
        q = t + nl;
        final kind = b[q++];
        if (kind == 0) {
          var (_, u) = leb(q);
          q = u;
        } else if (kind == 1) {
          q++;
          final flag = b[q++];
          var (_, u) = leb(q);
          q = u;
          if (flag != 0) {
            var (_, v) = leb(q);
            q = v;
          }
        } else if (kind == 2) {
          final flag = b[q++];
          var (_, u) = leb(q);
          q = u;
          if (flag != 0) {
            var (_, v) = leb(q);
            q = v;
          }
        } else {
          q += 2;
        }
        if (mod == 'hal') out.add(nm);
      }
    }
    i = end;
  }
  return out;
}
