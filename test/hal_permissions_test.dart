/*
 * A wapp does not get a transport by importing its symbol.
 *
 * The engine used to offer every HAL import to every module and swallow the
 * failure when the module did not declare one, so the wasm's own import table
 * was the access-control list -- written by whoever compiled the wasm. Any
 * wapp that added `hal_lxmf_recv` received every private message on the
 * device (`_lxmfInbox` has no recipient test); `hal_ble_scan_read` handed out
 * every raw radio frame with `from` and `rssi`.
 *
 * Tolerable while every wapp is ours. Not tolerable once somebody else's can
 * be installed, which is the case this gate is built for.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/hal_permissions.dart';

void main() {
  group('the default is refuse', () {
    test('a wapp that declares nothing gets no transport', () {
      const none = <String>{};
      for (final imp in [
        'ble_scan_read',
        'ble_advertise',
        'rns_recv',
        'rns_broadcast',
        'socket_open',
        'lxmf_recv',
        'nostr_event_recv',
        'relay_dm_recv',
        'xprs_history',
      ]) {
        expect(halImportAllowed(imp, none), isFalse,
            reason: '$imp must not be reachable without a declaration');
      }
    });

    test('the content APIs and the event bus stay open to everyone', () {
      // This is the surface a well-behaved wapp is written against: hand the
      // core content, be handed content back. Neither names a radio.
      const none = <String>{};
      for (final imp in [
        'xprs_send',
        'msg_send',
        'msg_recv',
        'event_subscribe',
        'event_available',
        'event_recv',
        'kv_get',
        'kv_set',
        'identity_sign',
        'encrypt',
      ]) {
        expect(halImportAllowed(imp, none), isTrue,
            reason: '$imp is content, not transport — it must stay ungated');
      }
    });
  });

  group('a declaration grants exactly what it names', () {
    test('one permission does not unlock another', () {
      const onlyBle = {HalPermission.bleRaw};
      expect(halImportAllowed('ble_scan_read', onlyBle), isTrue);
      expect(halImportAllowed('lxmf_recv', onlyBle), isFalse);
      expect(halImportAllowed('nostr_event_recv', onlyBle), isFalse);
      expect(halImportAllowed('socket_open', onlyBle), isFalse);
    });

    test('the inbox of everybody\'s correspondence needs its own grant', () {
      expect(halImportAllowed('lxmf_recv', {HalPermission.lxmfInbox}), isTrue);
      expect(halImportAllowed('lxmf_recv', {HalPermission.spool}), isFalse);
    });
  });

  group('reading a manifest', () {
    test('declared permissions are granted', () {
      final g = declaredPermissions(
          '{"id":"x","permissions":["transport.ble.raw","archive.read"]}');
      expect(g, {HalPermission.bleRaw, HalPermission.spool});
    });

    test('an absent, empty or broken manifest grants nothing', () {
      // A manifest that cannot be read is not a manifest that consents.
      expect(declaredPermissions(null), isEmpty);
      expect(declaredPermissions(''), isEmpty);
      expect(declaredPermissions('{'), isEmpty);
      expect(declaredPermissions('{"id":"x"}'), isEmpty);
      expect(declaredPermissions('{"permissions":"all"}'), isEmpty,
          reason: 'a non-list must not be coerced into a grant');
      expect(declaredPermissions('[]'), isEmpty);
    });

    test('unknown permission strings grant nothing they do not name', () {
      final g = declaredPermissions('{"permissions":["transport.everything"]}');
      expect(halImportAllowed('lxmf_recv', g), isFalse);
    });
  });
}
