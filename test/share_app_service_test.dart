import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/share_app_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The test binding swaps in an HttpClient that answers 400 to everything;
  // this test talks to a real local server.
  HttpOverrides.global = null;

  late Directory dir;
  late File apk;
  final svc = ShareAppService.instance;
  final bytes = List<int>.generate(100000, (i) => i % 251);

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
        apkPath: apk.path, version: '9.9.9', abi: 'arm64-v8a', port: 0);

    final page = await get(port, '/');
    expect(page.statusCode, 200);
    final html = String.fromCharCodes(await body(page));
    expect(html, contains('href="/xprs-9.9.9.apk"'));

    final full = await get(port, '/xprs-9.9.9.apk');
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

    final part = await get(port, '/xprs-9.9.9.apk',
        headers: {'range': 'bytes=99000-'});
    expect(part.statusCode, 206);
    expect(part.headers.value('content-range'), 'bytes 99000-99999/100000');
    expect(await body(part), bytes.sublist(99000));

    final bad = await get(port, '/xprs-9.9.9.apk',
        headers: {'range': 'bytes=200000-'});
    expect(bad.statusCode, 416);
    await body(bad);

    final other = await get(port, '/etc/passwd');
    expect(other.statusCode, 404);
    await body(other);
  });

  test('wifi QR escapes special characters', () {
    expect(
        wifiQr(const ShareHotspot(ssid: 'a;b', psk: r'p:w\d', security: 'WPA')),
        r'WIFI:T:WPA;S:a\;b;P:p\:w\\d;;');
    expect(wifiQr(const ShareHotspot(ssid: 'open', psk: '', security: 'nopass')),
        'WIFI:T:nopass;S:open;;');
  });
}
