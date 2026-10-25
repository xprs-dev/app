/*
 * xprs_identity_adopt — what has to happen the moment this station's name
 * changes.
 *
 * An operator setting their licensed callsign (XPRS.md 6.4.1) changes what
 * goes in `f:` on every packet, what the Reticulum announce says this station
 * is called, and what the signed `t:identity` binds to their key. None of that
 * is the profile editor's business: it writes a field and the air catches up.
 *
 * This is the one place that makes it catch up, and it exists because
 * `ProfileService.activeProfileNotifier` could not do it. That notifier
 * carries the profile ID, and the ID is the folder on disk (devices/X1ABCD/),
 * which must not move. So the edit that matters most to the air was the one
 * edit nothing was listening for. `ProfileService.wireCallsignNotifier` is the
 * signal; this is its listener.
 *
 * Deliberately NOT here:
 *
 * - The Reticulum announce name, which `rns_autostart` already owns and now
 *   listens for itself. Two owners of one announce is how a station ends up
 *   announcing twice under two names.
 * - The GATT local name, which `BleService._armGattEndpoint` re-arms on its
 *   own 30-second heartbeat. Forcing it early would restart a healthy advert,
 *   and docs/ble5.md section 2 says a restart rotates the address.
 * - The relay directory record (`publishIdentityToRelays`), which is reached
 *   only from `hal_relay_identity_publish` with the WAPP's own callsign, so it
 *   republishes when the wapp next reads `hal_identity`. Its kind-30078 event
 *   is replaceable on `(pubkey, kind, d)` and `d` is the callsign, so the OLD
 *   record survives and goes on resolving to the same key and the same
 *   destinations. That is exactly what we want: it is how a sender who only
 *   knows the old name still reaches us.
 * - Restarting background wapps. A wapp reads `hal_identity` once at init
 *   (../apps/chat/main.c), so one already running keeps the old name until it
 *   is reopened. Restarting them from here would be new behaviour that a
 *   profile SWITCH does not have either, and the right fix is a wapp
 *   re-reading `hal_identity` on a core event. The profile screen says so to
 *   the operator instead of this pretending to handle it.
 */
library;

import 'dart:async';

import '../../profile/profile_service.dart';
import '../log_service.dart';
import '../mesh/mesh_service.dart';
import 'xprs_publisher.dart';

bool _bound = false;

/// Listen for this station's aired callsign changing, and bring the air with
/// it. Idempotent; call once at startup.
void xprsBindWireCallsign() {
  if (_bound) return;
  _bound = true;
  ProfileService.instance.wireCallsignNotifier.addListener(_adopt);
  // A callsign added or removed without changing the one on the air: the
  // same two steps -- the alias set is rebuilt and every binding re-aired.
  ProfileService.instance.callsignsNotifier.addListener(_adoptSet);
}

String _lastSet = '';

void _adoptSet() {
  final all = ProfileService.instance.callsignsNotifier.value;
  if (all.isEmpty || all == _lastSet) return;
  final first = _lastSet.isEmpty;
  _lastSet = all;
  if (first) return;          // the initial load; _adopt covers it
  LogService.instance.add('XPRS: answering to $all');
  unawaited(MeshService.instance
      .start(canAdvertise: MeshService.instance.canAdvertise));
  unawaited(XprsPublisher.instance.publishIdentity());
}

void _adopt() {
  final cs = ProfileService.instance.wireCallsignNotifier.value;
  if (cs.isEmpty) return; // no profile, or the last one was deleted
  LogService.instance.add('XPRS: now transmitting as $cs');

  // 1. The mesh table, and through it XprsArchive's `selfCallsign` and the
  //    alias set the receive door answers to. `start` compares the new name
  //    against the table it holds and rebuilds when they differ, so this is
  //    also the cheapest way to get everything downstream of it re-set.
  unawaited(MeshService.instance
      .start(canAdvertise: MeshService.instance.canAdvertise));

  // 2. The signed binding, XPRS.md 6.4.2: `t:identity f:<callsign> k:<npub>`,
  //    self-signed, on every active bearer. It is what lets a peer check a
  //    signature of ours at all, and under a NEW name nobody holds a binding
  //    for, every packet we send reads `unverified` until this goes out. It
  //    is re-aired every 30 minutes anyway (29.1); waiting that long is the
  //    difference between a rename that works and one that looks broken.
  //
  //    Also on CLEARING a licensed callsign, for the same reason in reverse.
  unawaited(XprsPublisher.instance.publishIdentity());
}
