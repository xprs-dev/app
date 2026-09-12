/*
 * What the core owes a wapp that sets a station up (XPRS.md 11.9, 11.10),
 * and what it must never do with what the wapp hands it.
 *
 * The Firmwares wapp claims a freshly flashed station and seals a WiFi
 * password to it. Four things under it are the core's, each tested here
 * rather than trusted:
 *
 *   - a password typed into a `$type:"secret"` field is written down nowhere;
 *   - a command that changes a station is never left with an archiver;
 *   - a station's ask to be claimed binds its key, so that very packet reads
 *     as verified, and reaches the wapp on `xprs.request`;
 *   - the key a sealed body goes to may be given as it arrived, an npub.
 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';
import 'package:xprs/services/receive/wapp_delivery.dart';
import 'package:xprs/services/xprs/xprs_ingest.dart';
import 'package:xprs/services/xprs/xprs_mailbox.dart';
import 'package:xprs/services/xprs/xprs_monitor.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/util/nostr_crypto.dart';
import 'package:xprs/util/xprs_crypto.dart';
import 'package:xprs/wapp/geoui/geoui_parser.dart';
import 'package:xprs/wapp/geoui/geoui_renderer.dart';
import 'package:xprs/wapp/wapp_event_broker.dart';
import 'package:xprs/wapp/wapp_secret_fields.dart';

XprsPacket _p(String w) => XprsPacket.parse(w)!;

const _screen = '''
[{"\$": "screen", "name": "Station", "children": [
  {"\$": "group", "name": "wifi", "children": [
    {"\$": "field", "name": "ssid", "\$type": "string"},
    {"\$": "field", "name": "wifi_pass", "\$type": "secret"}
  ]},
  {"\$": "field", "name": "nsec", "\$type": "secret"},
  {"\$": "field", "name": "nick", "\$type": "string"}
]}]
''';

void main() {
  group('a secret field is written down nowhere', () {
    test('every secret field in a screen is found, however deep', () {
      final out = <String>{};
      for (final b in GeoUiParser(_screen).parse().blocks) {
        collectSecretFields(b, out);
      }
      expect(out, {'wifi_pass', 'nsec'});
    });

    test('what the host may store leaves the secrets out, and only them', () {
      final kept = wappStorableFields(
        {'ssid': 'Casa do Mar', 'wifi_pass': 'sardinha', 'nick': 'roof', 'nsec': 'nsec1x'},
        {'wifi_pass', 'nsec'},
      );
      expect(kept, {'ssid': 'Casa do Mar', 'nick': 'roof'});
    });
  });

  group('a command that changes a station is never deposited (11.4)', () {
    const env = 't:command f:X1QZ3N d:X3RLY7 ts:2026-08-08_14:31:00';
    test('cmd:set, cmd:update and anything sealed stay home', () {
      expect(XprsMailbox.worthKeeping(_p('$env cmd:set nick:roof')), isFalse);
      expect(XprsMailbox.worthKeeping(_p('$env cmd:set owner:X1QZ3N')), isFalse);
      expect(XprsMailbox.worthKeeping(_p('$env cmd:update ver:1.0.0')), isFalse);
      expect(XprsMailbox.worthKeeping(_p('$env cmd:zdiag')), isFalse,
          reason: 'a stats ask answered tomorrow answers nobody');
      expect(XprsMailbox.worthKeeping(_p('$env x:${'C' * 107}')), isFalse,
          reason: 'a sealed WiFi password left with a stranger is still a secret');
    });
    test('a history or file ask is still worth asking late', () {
      expect(XprsMailbox.worthKeeping(_p('$env cmd:history')), isTrue);
      expect(XprsMailbox.worthKeeping(_p('$env cmd:file file:${'A' * 43}.jpg')), isTrue);
    });
  });

  group('a station asking to be claimed', () {
    // A toy station key: never sign with it.
    final d = BigInt.parse('22' * 32, radix: 16);
    final x = XprsCrypto.publicKeyXOnly(d);
    final npub = NostrCrypto.encodeNpub(HEX.encode(x));
    final call = 'X3${npub.substring(5, 9).toUpperCase()}';
    final ask = xprsSign(
        _p('t:request f:$call q:owner scope:local ts:2026-09-11_18:00:00 k:$npub'), d);

    tearDown(() => XprsIngest.onIdentity = null);

    test('binds the key it carries, as t:identity does', () {
      String? bound;
      XprsIngest.onIdentity = (c, hex) => bound = '$c $hex';
      XprsIngest.heard(ask, bearer: 'ble', selfCallsign: 'X1TEST');
      expect(bound, '$call ${HEX.encode(x)}');
    });

    test("a new key's first answer binds it, when the callsign derives", () {
      String? bound;
      XprsIngest.onIdentity = (c, hex) => bound = '$c $hex';
      final r = xprsSign(
          _p('t:result f:$call d:X1TEST ts:2026-09-11_18:01:00 r:6e945a code:200 k:$npub'), d);
      XprsIngest.heard(r, bearer: 'lan', selfCallsign: 'X1TEST');
      expect(bound, '$call ${HEX.encode(x)}');
    });

    test("a key offered for somebody else's name binds nothing", () {
      String? bound;
      XprsIngest.onIdentity = (c, hex) => bound = c;
      final r = xprsSign(
          _p('t:result f:X3ZZZZ d:X1TEST ts:2026-09-11_18:01:00 r:6e945a code:200 k:$npub'), d);
      XprsIngest.heard(r, bearer: 'lan', selfCallsign: 'X1TEST');
      expect(bound, isNull);
    });

    test('a forged ask binds nothing', () {
      String? bound;
      XprsIngest.onIdentity = (c, hex) => bound = c;
      final other = BigInt.parse('33' * 32, radix: 16);
      final forged = xprsSign(
          _p('t:request f:$call q:owner scope:local ts:2026-09-11_18:00:01 k:$npub'),
          other);
      XprsIngest.heard(forged, bearer: 'ble', selfCallsign: 'X1TEST');
      expect(bound, isNull);
    });

    test('reaches a wapp on xprs.request, key and all', () {
      final bus = WappEventBroker.instance;
      for (final id in bus.registeredEngines().toList()) {
        bus.unregisterEngine(id);
      }
      WappDelivery.debugReset();
      bus.registerEngine('firmwares');
      bus.subscribe('firmwares', rxTopicFor('request'));
      bus.subscribe('firmwares', rxTopicFor('identity'));
      WappDelivery.instance.deliverPacket(ask, bearer: 'ble', forUs: false);
      final row = jsonDecode(bus.recv('firmwares')!.data) as Map<String, dynamic>;
      expect(row['type'], 'request');
      expect(row['from'], call);
      expect(row['wire'], contains('k:$npub'));

      final id = xprsSign(_p('t:identity f:$call ts:2026-09-11_18:00:02 k:$npub'), d);
      WappDelivery.instance.deliverPacket(id, bearer: 'ble', forUs: false);
      final row2 = jsonDecode(bus.recv('firmwares')!.data) as Map<String, dynamic>;
      expect(row2['type'], 'identity');
    });
  });

  group('a sealed body opens at the station it was sealed to', () {
    test('an npub and its base64url name the same key', () {
      final phone = BigInt.parse('11' * 32, radix: 16);
      final station = BigInt.parse('22' * 32, radix: 16);
      final sx = XprsCrypto.publicKeyXOnly(station);
      final body = Uint8List.fromList(utf8.encode('cmd:set\npass:sardinha na brasa'));
      final blob = XprsCrypto.encryptFor(phone, sx, body)!;
      final back = XprsCrypto.decryptFrom(station, XprsCrypto.publicKeyXOnly(phone), blob);
      expect(utf8.decode(back!), 'cmd:set\npass:sardinha na brasa');
      // The engine accepts either spelling for the same 32 bytes.
      final npub = NostrCrypto.encodeNpub(HEX.encode(sx));
      expect(HEX.decode(NostrCrypto.decodeNpub(npub)), sx);
    });
  });

  testWidgets('the secret field is obscured and the keyboard does not learn it',
      (tester) async {
    // The renderer on its own: the host's storage rule is above, this is the
    // screen's half.
    final screen = GeoUiParser(_screen).parse().blocks.first;
    final values = <String, dynamic>{};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: GeoUiScreenRenderer(screen: screen, bindings: _Values(values)),
        ),
      ),
    ));
    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    final secret = fields.where((f) => f.obscureText).toList();
    expect(secret.length, 2, reason: 'wifi_pass and nsec');
    for (final f in secret) {
      expect(f.enableSuggestions, isFalse);
      expect(f.autocorrect, isFalse);
      expect(f.enableIMEPersonalizedLearning, isFalse);
    }
  });

  testWidgets('a hidden action or field is left off the screen', (tester) async {
    // `<name>__hidden` is a host flag the wapp sets with ui.field.set, the
    // way `__readonly` disables: the station screen shows Claim only while
    // nobody owns the station.
    const hub = '''
[{"\$": "screen", "name": "Station", "children": [
  {"\$": "field", "name": "ssid", "\$type": "string"},
  {"\$": "action", "name": "claim", "label": "Claim", "style": "primary"},
  {"\$": "action", "name": "open_wifi", "label": "WiFi", "icon": "wifi"}
]}]''';
    final screen = GeoUiParser(hub).parse().blocks.first;
    final values = <String, dynamic>{'claim__hidden': true, 'ssid__hidden': true};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: GeoUiScreenRenderer(screen: screen, bindings: _Values(values)),
        ),
      ),
    ));
    expect(find.text('Claim'), findsNothing);
    expect(find.text('WiFi'), findsOneWidget);
    expect(find.byIcon(Icons.wifi), findsOneWidget, reason: 'a known icon rides its button');
    expect(find.byType(TextField), findsNothing);
  });

  group('one station, through one verb', () {
    test('hal_xprs_station reads what the monitor holds, fw included', () {
      final m = XprsMonitor.instance..clear();
      m.offer(_p('t:service f:X3RLY7 serve:archive count:1234 fw:1.4.2 mail:3 uptime:26h lifetime:38day'),
          bearer: 'lan', selfCallsign: 'X1QZ3N', nowMs: 1000);
      m.offer(_p('t:observation f:X3RLY7 link:ble peers:4 hears:X1WATT,X3MEAV'),
          bearer: 'ble', selfCallsign: 'X1QZ3N', rssi: -71, nowMs: 5000);
      final row = m.stationJson('x3rly7', nowMs: 17000)!;
      expect(row['fw'], '1.4.2');
      expect(row['uptime'], '26h');
      expect(row['lifetime'], '38day');
      expect(row['peers'], 4);
      expect(row['mail'], 3);
      expect(row['count'], 1234);
      expect(row['serve'], ['archive']);
      expect(row['hears'], ['X1WATT', 'X3MEAV']);
      expect(row['bearer'], 'ble');
      expect(row['rssi'], -71);
      expect(row['agoMs'], 12000);
      expect((row['bearers'] as List).toSet(), {'lan', 'ble'});
      expect(m.stationJson('X3NONE', nowMs: 17000), isNull);
      // A message says nothing about the firmware, and does not erase it.
      m.offer(_p('t:message f:X3RLY7 m:hello'), bearer: 'lan', selfCallsign: 'X1QZ3N', nowMs: 20000);
      expect(m.stationJson('X3RLY7', nowMs: 21000)!['fw'], '1.4.2');
      m.clear();
    });
  });

  test('a packet nobody subscribed to is not verified for delivery', () {
    // The verdict is a curve operation on the UI isolate; most of what a
    // busy station hears is on topics no wapp asked for.
    final before = WappDelivery.published;
    final n = WappDelivery.instance.deliverPacket(
        _p('t:observation f:X3RLY7 link:ble peers:4 sig:${'K' * 60}'),
        bearer: 'ble', forUs: false);
    expect(n, 0);
    expect(WappDelivery.published, before + 1);
  });
}

class _Values implements GeoUiBindings {
  _Values(this.v);
  final Map<String, dynamic> v;
  @override
  dynamic getValue(String fieldName) => v[fieldName];
  @override
  void setValue(String fieldName, dynamic value) => v[fieldName] = value;
}
