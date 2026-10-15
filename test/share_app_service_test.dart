import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/share_app_service.dart';
import 'package:xprs/services/web_chat_api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding swaps in an HttpClient that answers 400 to everything;
  // this test talks to a real local server.
  HttpOverrides.global = null;

  late Directory dir;
  late File apk;
  final svc = ShareAppService.instance;
  final bytes = List<int>.generate(100000, (i) => i % 251);
  final chatGz = Uint8List.fromList(gzip.encode(utf8.encode('<html>the chat</html>')));
  final sent = <String>[];
  WebChatApi api({String? app = '/app'}) => WebChatApi(
        publicRows: ({sinceMs, untilMs, required types, from, visitor, required limit}) =>
            [
              {'type': 'message', 'from': 'X1ARKL', 'to': '', 'own': false, 'wire': 't:message f:X1ARKL m:hi'},
            ],
        held: (_) => 1,
        receive: sent.add,
        mayAir: (_) => true,
        selfCallsign: () => 'X1SELF',
        keyOf: (_) => null,
        appPath: () => app,
      );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('share_app_test');
    apk = File('${dir.path}/base.apk');
    await apk.writeAsBytes(bytes);
  });

  tearDown(() async {
    await svc.stop();
    await dir.delete(recursive: true);
  });

  Future<HttpClientResponse> get(int port, String path,
      {Map<String, String> headers = const {}}) async {
    final c = HttpClient();
    final req = await c.get('127.0.0.1', port, path);
    headers.forEach(req.headers.set);
    return req.close();
  }

  Future<List<int>> body(HttpClientResponse r) async =>
      (await r.toList()).expand((e) => e).toList();

  test('serves the page, the apk, a resumed range, and nothing else', () async {
    final port = await svc.start(
        apkPath: apk.path,
        version: '9.9.9',
        abi: 'arm64-v8a',
        port: 0,
        api: api(),
        chatPageGz: chatGz);

    final page = await get(port, '/app');
    expect(page.statusCode, 200);
    final html = String.fromCharCodes(await body(page));
    expect(html, contains('href="/app/xprs-9.9.9.apk"'));

    final full = await get(port, '/app/xprs-9.9.9.apk');
    expect(full.statusCode, 200);
    expect(full.headers.contentType?.mimeType,
        'application/vnd.android.package-archive');
    expect(full.contentLength, bytes.length);
    expect(await body(full), bytes);
    // The server counts once its pipe completes, a beat after the client has
    // the last byte.
    for (var i = 0; i < 50 && svc.downloads.value == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(svc.downloads.value, 1);

    // The addresses already handed out keep working.
    final legacy = await get(port, '/xprs-9.9.9.apk');
    expect(legacy.statusCode, 200);
    expect(await body(legacy), bytes);

    final part = await get(port, '/app/xprs-9.9.9.apk',
        headers: {'range': 'bytes=99000-'});
    expect(part.statusCode, 206);
    expect(part.headers.value('content-range'), 'bytes 99000-99999/100000');
    expect(await body(part), bytes.sublist(99000));

    final bad = await get(port, '/app/xprs-9.9.9.apk',
        headers: {'range': 'bytes=200000-'});
    expect(bad.statusCode, 416);
    await body(bad);

    final other = await get(port, '/etc/passwd');
    expect(other.statusCode, 404);
    await body(other);
  });

  test('the root is the web chat, gzipped or not as the client asks', () async {
    final port = await svc.start(port: 0, api: api(app: null), chatPageGz: chatGz);
    final raw = HttpClient()..autoUncompress = false;
    final rq = await raw.get('127.0.0.1', port, '/');
    rq.headers.set('accept-encoding', 'gzip');
    final z = await rq.close();
    expect(z.statusCode, 200);
    expect(z.headers.value('content-encoding'), 'gzip');
    expect(utf8.decode(gzip.decode(await body(z))), '<html>the chat</html>');
    final pq = await raw.get('127.0.0.1', port, '/');
    pq.headers.set('accept-encoding', 'identity');
    final plain = await pq.close();
    expect(plain.headers.value('content-encoding'), isNull);
    expect(utf8.decode(await body(plain)), '<html>the chat</html>');
  });

  test('a copy that cannot be handed on still hosts the chat, with no /app',
      () async {
    final port = await svc.start(port: 0, api: api(app: null), chatPageGz: chatGz);
    expect(svc.apkShareable, isFalse);
    final r = await get(port, '/app');
    expect(r.statusCode, 404);
    await body(r);
    final s = await get(port, '/api/services');
    final j = jsonDecode(utf8.decode(await body(s))) as Map;
    expect((j['page'] as Map).containsKey('app'), isFalse);
  });

  test('the api answers under /api and nothing else leaks', () async {
    final port = await svc.start(
        apkPath: apk.path, version: '1', port: 0, api: api(), chatPageGz: chatGz);
    final s = await get(port, '/api/services');
    final j = jsonDecode(utf8.decode(await body(s))) as Map;
    expect((j['page'] as Map)['app'], '/app');
    final h = await get(port, '/api/xprs/history?kind=message');
    final hj = jsonDecode(utf8.decode(await body(h))) as Map;
    expect((hj['rows'] as List).single['from'], 'X1ARKL');
    final nope = await get(port, '/api/xprs/bearers');
    expect(nope.statusCode, 404, reason: 'the remote api is not mounted here');
    await body(nope);
    expect(svc.visitors, 1);
  });

  test('wifi QR escapes special characters', () {
    expect(
        wifiQr(const ShareHotspot(ssid: 'a;b', psk: r'p:w\d', security: 'WPA')),
        r'WIFI:T:WPA;S:a\;b;P:p\:w\\d;;');
    expect(wifiQr(const ShareHotspot(ssid: 'open', psk: '', security: 'nopass')),
        'WIFI:T:nopass;S:open;;');
  });
}
