// The remote API can install updates and send as the user, so it must be
// unreachable from the network and from a web page (GHSA-6m5w-4w3h-c2j9).
// It listens on loopback only and refuses anything a browser sends.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/preferences_service.dart';
import 'package:xprs/services/remote_api_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding fakes every HttpClient with a 400; this test needs the
  // real socket.
  HttpOverrides.global = null;
  const port = 34561;

  setUpAll(() => RemoteApiService.instance.start(port: port));
  tearDownAll(() => RemoteApiService.instance.stop());

  Future<int> get(String host, {Map<String, String> headers = const {}}) async {
    final c = HttpClient();
    try {
      final req = await c.get('127.0.0.1', port, '/api/log?n=1');
      req.headers.host = host;
      headers.forEach(req.headers.set);
      final res = await req.close();
      await res.drain<void>();
      return res.statusCode;
    } finally {
      c.close(force: true);
    }
  }

  test('a bench tool on loopback is answered', () async {
    expect(await get('127.0.0.1'), 200);
    expect(await get('localhost'), 200);
  });

  test('a browser request is refused', () async {
    expect(await get('127.0.0.1', headers: {'Origin': 'https://evil.example'}),
        403);
    expect(await get('127.0.0.1', headers: {'Sec-Fetch-Site': 'cross-site'}),
        403);
  });

  test('a rebound host name is refused', () async {
    expect(await get('evil.example'), 403);
  });

  test('no CORS header is sent', () async {
    final c = HttpClient();
    try {
      final res = await (await c.get('127.0.0.1', port, '/api/log?n=1')).close();
      await res.drain<void>();
      expect(res.headers.value('access-control-allow-origin'), isNull);
    } finally {
      c.close(force: true);
    }
  });

  test('it is not reachable on a LAN address', () async {
    final lan = (await NetworkInterface.list(type: InternetAddressType.IPv4))
        .expand((i) => i.addresses)
        .where((a) => !a.isLoopback)
        .toList();
    for (final a in lan) {
      await expectLater(
          Socket.connect(a, port, timeout: const Duration(seconds: 1)),
          throwsA(isA<SocketException>()));
    }
  });

  test('the API is off unless the user turns it on', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await PreferencesService.instance();
    expect(prefs.remoteApiEnabled, isFalse);
  });
}
