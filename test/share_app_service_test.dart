import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/share_app_service.dart';
import 'package:xprs/services/share_library.dart';
import 'package:xprs/services/update_models.dart';
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
  final chatHtml = Uint8List.fromList(utf8.encode('<html>the chat</html>'));
  final sent = <String>[];
  WebChatApi api({String? app = '/app'}) => WebChatApi(
        publicRows: ({sinceMs, untilMs, required types, from, visitor, room, required limit}) =>
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

  test('starts with a live API that holds a Timer (the archive does)',
      () async {
    // The live API's callbacks reach XprsArchive, which holds a Timer. Share
    // compressed the page on a worker isolate with a closure that captured
    // the service, and with it the Timer: "object is unsendable", and the
    // Share page showed the exception instead of sharing.
    final timer = Timer(const Duration(hours: 1), () {});
    addTearDown(timer.cancel);
    final held = WebChatApi(
      publicRows: ({sinceMs, untilMs, required types, from, visitor, room, required limit}) => const [],
      held: (_) => timer.isActive ? 1 : 0,
      receive: sent.add,
      mayAir: (_) => true,
      selfCallsign: () => 'X1SELF',
      keyOf: (_) => null,
      appPath: () => null,
    );
    final port = await svc.start(port: 0, api: held, chatPage: chatHtml);
    final r = await get(port, '/');
    expect(r.statusCode, 200);
  });

  test('serves the page, the apk, a resumed range, and nothing else', () async {
    final port = await svc.start(
        apkPath: apk.path,
        version: '9.9.9',
        abi: 'arm64-v8a',
        port: 0,
        api: api(),
        chatPage: chatHtml);

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
    final port = await svc.start(port: 0, api: api(app: null), chatPage: chatHtml);
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
    final port = await svc.start(port: 0, api: api(app: null), chatPage: chatHtml);
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
        apkPath: apk.path, version: '1', port: 0, api: api(), chatPage: chatHtml);
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

  test('installers for other systems are served next to this copy',
      () async {
    final exe = File('${dir.path}/xprs-9.9.9-windows-x64-setup.exe');
    await exe.writeAsBytes(bytes.sublist(0, 5000));
    final tgz = File('${dir.path}/xprs-9.9.9-linux-x64.tar.gz');
    await tgz.writeAsBytes(bytes.sublist(0, 7000));
    final other = File('${dir.path}/xprs-9.9.9-android-arm64-v8a.apk');
    await other.writeAsBytes(bytes.sublist(0, 100));
    List<ShareEntry> lib() => [
          ShareEntry(
              platform: UpdatePlatform.android,
              name: 'xprs-9.9.9-android-arm64-v8a.apk',
              path: other.path,
              size: 100),
          ShareEntry(
              platform: UpdatePlatform.windows,
              name: 'xprs-9.9.9-windows-x64-setup.exe',
              path: exe.path,
              size: 5000),
          ShareEntry(
              platform: UpdatePlatform.linux,
              name: 'xprs-9.9.9-linux-x64.tar.gz',
              path: tgz.path,
              size: 7000),
        ];
    final port = await svc.start(
        apkPath: apk.path,
        version: '9.9.9',
        port: 0,
        api: api(),
        chatPage: chatHtml,
        library: lib);
    final html = String.fromCharCodes(await body(await get(port, '/app')));
    expect(html, contains('href="/app/xprs-9.9.9.apk"'));
    expect(html, contains('href="/app/xprs-9.9.9-windows-x64-setup.exe"'));
    expect(html, contains('href="/app/xprs-9.9.9-linux-x64.tar.gz"'));
    // This copy is the Android one; the library's APK is not offered twice.
    expect(html, isNot(contains('android-arm64-v8a.apk')));
    final w = await get(port, '/app/xprs-9.9.9-windows-x64-setup.exe');
    expect(w.statusCode, 200);
    expect(await body(w), bytes.sublist(0, 5000));
    final l = await get(port, '/app/xprs-9.9.9-linux-x64.tar.gz');
    expect(l.headers.contentType?.mimeType, 'application/gzip');
    expect(await body(l), bytes.sublist(0, 7000));
    final hidden = await get(port, '/app/xprs-9.9.9-android-arm64-v8a.apk');
    expect(hidden.statusCode, 404);
    await body(hidden);
  });

  test('a desktop with no APK of its own serves the library alone', () async {
    final tgz = File('${dir.path}/xprs-1.0.0-android-arm64-v8a.apk');
    await tgz.writeAsBytes(bytes.sublist(0, 3000));
    final port = await svc.start(
        port: 0,
        api: api(),
        chatPage: chatHtml,
        library: () => [
              ShareEntry(
                  platform: UpdatePlatform.android,
                  name: 'xprs-1.0.0-android-arm64-v8a.apk',
                  path: tgz.path,
                  size: 3000),
            ]);
    expect(svc.apkShareable, isFalse);
    final r = await get(port, '/app/xprs-1.0.0-android-arm64-v8a.apk');
    expect(r.statusCode, 200);
    expect(await body(r), bytes.sublist(0, 3000));
    // The aliases belong to this copy only.
    final alias = await get(port, '/xprs.apk');
    expect(alias.statusCode, 404);
    await body(alias);
  });

  test('a visitor is offered the addresses of real networks only', () {
    int? rank(String n) => shareInterfaceRank(n);
    expect(rank('ap0'), 0);
    expect(rank('swlan0'), 0);
    expect(rank('wlan0'), 1);
    expect(rank('wlp2s0'), 1);
    expect(rank('Wi-Fi'), 1);
    expect(rank('eth0'), 2);
    expect(rank('enp3s0'), 2);
    expect(rank('en0'), 2);
    expect(rank('Ethernet'), 2);
    for (final n in [
      'rmnet_data0', 'tun0', 'docker0', 'veth12ab', 'br-1234', 'virbr0',
      'tailscale0', 'wg0', 'utun3', 'awdl0', 'vEthernet (WSL)',
      'VirtualBox Host-Only Network', 'zt5u4y'
    ]) {
      expect(rank(n), isNull, reason: n);
    }
  });

  test('an artifact name says which system it is for', () {
    expect(sharePlatformOf('xprs-1.2.3-android-arm64-v8a.apk'),
        UpdatePlatform.android);
    expect(sharePlatformOf('xprs-1.2.3-beta.1-windows-x64-setup.exe'),
        UpdatePlatform.windows);
    expect(sharePlatformOf('xprs-1.2.3-linux-x64.tar.gz'), UpdatePlatform.linux);
    expect(sharePlatformOf('notes.txt'), isNull);
    expect(sharePlatformOf('xprs-1.2.3-android-arm64-v8a.apk.part'), isNull);
  });
}
