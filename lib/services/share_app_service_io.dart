/*
 * ShareAppService on native: the HTTP server that hands out this APK, and the
 * channel to ShareBridge.kt for the APK path and the LocalOnlyHotspot.
 *
 * Runs on the UI isolate, which is fine for what it does: the file is streamed
 * with openRead().pipe (async, chunked, never the whole APK on the heap) and
 * nothing is hashed or parsed. The platform channel is main-isolate only
 * anyway.
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'background_service.dart';
import 'log_service.dart';
import 'mesh/mesh_service.dart';
import 'receive/packet_gateway.dart';
import 'share_app_types.dart';
import 'web_chat_api.dart';
import '../wapp/android_foreground_service.dart';
import 'xprs/xprs_archive.dart';
import 'xprs/xprs_publisher.dart';

export 'share_app_types.dart';

class ShareAppService {
  ShareAppService._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'hotspotStopped') {
        hotspotUp.value = false;
        hotspot = null;
      }
    });
  }
  static final ShareAppService instance = ShareAppService._();

  /// Tried first so the URL is easy to type by hand; any free port otherwise.
  static const int preferredPort = 8642;

  static const _channel = MethodChannel('com.xprs.app/share');

  /// Completed APK transfers since the page opened.
  final ValueNotifier<int> downloads = ValueNotifier<int>(0);
  final ValueNotifier<bool> hotspotUp = ValueNotifier<bool>(false);

  /// The hotspot this service started, while it is up, so the page can show
  /// its QR again after the person left it and came back.
  ShareHotspot? hotspot;

  /// The web chat page, built in the `webchat` repo and bundled as plain
  /// HTML: F-Droid's scanner refuses any archive in the source tree, a gzip
  /// included (it failed the v1.2.28 release build). It is gzipped once, when
  /// the server starts, for clients that take gzip.
  static const String chatAsset = 'assets/web_chat/chat_page.html';

  HttpServer? _server;
  WebChatApi? _api;
  Uint8List? _chatHtml;
  Uint8List? _chatGz;
  String _apkPath = '';
  String _version = '';
  String _abi = '';

  bool get running => _server != null;

  /// Whether this copy can be handed on as one file.
  bool get apkShareable => _apkPath.isNotEmpty;

  /// Visitors that have reached the web chat since it started.
  int get visitors => _api?.visitors.length ?? 0;
  final ValueNotifier<int> visitorCount = ValueNotifier<int>(0);
  int get port => _server?.port ?? 0;
  String get apkName => 'xprs-$_version.apk';

  Future<ShareApkInfo?> apkInfo() async {
    if (!Platform.isAndroid) return null;
    final m = await _channel.invokeMapMethod<String, dynamic>('apkInfo');
    if (m == null) return null;
    return ShareApkInfo(
      path: m['path'] as String? ?? '',
      splits: m['splits'] as int? ?? 0,
      size: m['size'] as int? ?? 0,
      abi: m['abi'] as String? ?? '',
    );
  }

  Future<ShareHotspot> startHotspot() async {
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('startHotspot');
      final ssid = m?['ssid'] as String? ?? '';
      if (ssid.isEmpty) throw const ShareAppException('generic');
      hotspotUp.value = true;
      return hotspot = ShareHotspot(
        ssid: ssid,
        psk: m?['psk'] as String? ?? '',
        security: m?['security'] as String? ?? 'WPA',
      );
    } on PlatformException catch (e) {
      throw ShareAppException(e.code);
    } on MissingPluginException {
      throw const ShareAppException('unsupported');
    }
  }

  Future<void> stopHotspot() async {
    hotspotUp.value = false;
    hotspot = null;
    try {
      await _channel.invokeMethod<void>('stopHotspot');
    } catch (_) {}
  }

  /// Start serving: the web chat at `/`, its API under `/api/`, and, when
  /// [apkPath] names one, this app's APK under `/app`. Returns the port.
  /// [port], [api] and [chatPage] are for tests; the page leaves them null
  /// and gets [preferredPort] when it is free, the live API and the bundled
  /// page.
  Future<int> start({
    String apkPath = '',
    String version = '',
    String abi = '',
    int? port,
    WebChatApi? api,
    Uint8List? chatPage,
  }) async {
    _apkPath = apkPath;
    _version = version;
    _abi = abi;
    if (_server != null) return _server!.port;
    _api = api ?? _liveApi();
    visitorCount.value = 0;
    _api!.onVisitors = (n) => visitorCount.value = n;
    final html = _chatHtml = chatPage ??
        (await rootBundle.load(chatAsset)).buffer.asUint8List();
    // 80 KB deflated once per start, off the UI isolate (performance.md:
    // compression is worker work).
    _chatGz = await BackgroundService.runOffThread(
        () async => Uint8List.fromList(gzip.encode(html)));
    HttpServer server;
    try {
      server = await HttpServer.bind(
          InternetAddress.anyIPv4, port ?? preferredPort);
    } on SocketException {
      server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    }
    // A phone that walked out of range mid-download leaves a socket behind;
    // do not keep it for the default two minutes.
    server.idleTimeout = const Duration(seconds: 20);
    _server = server;
    downloads.value = 0;
    server.listen(_handle, onError: (_) {});
    // Sharing outlives the page: a visitor chats with the screen off. The
    // foreground service holds the process until [stop] releases it.
    unawaited(AndroidForegroundService.instance.hold(_holder));
    LogService.instance.add('share-app: serving on port ${server.port}');
    return server.port;
  }

  /// The API a visitor's browser gets, wired to the core: what it posts goes
  /// through the one receive door (as heard on the hotspot, `wifi`), which the
  /// bridge and digipeater carry on under the owner's policy; what it reads is
  /// the archive's undirected rows.
  WebChatApi _liveApi() => WebChatApi(
        publicRows: archivePublicRows,
        held: (t) => XprsArchive.instance.countOf(types: t, undirected: true),
        receive: (w) => PacketGateway.instance.receive(
            Uint8List.fromList(utf8.encode(w)),
            bearer: 'wifi', lane: RxLane.datagram),
        mayAir: XprsPublisher.instance.mayAir,
        selfCallsign: () => MeshService.instance.tableCallsign,
        keyOf: (c) => XprsArchive.instance.keyResolver?.call(c),
        appPath: () => apkShareable ? '/app' : null,
      );

  static const String _holder = 'share';

  /// Stop serving, release the process and take the hotspot down.
  Future<void> stopSharing() async {
    await stop();
    await stopHotspot();
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    unawaited(AndroidForegroundService.instance.release(_holder));
    if (s != null) {
      await s.close(force: true);
      LogService.instance.add('share-app: stopped');
    }
  }

  /// IPv4 addresses another phone could reach us on, best first: the hotspot
  /// interface, then Wi-Fi, then anything else that is not cellular or a
  /// tunnel (those are never on the same network as a phone next to us).
  Future<List<String>> localAddresses() async {
    final ranked = <MapEntry<int, String>>[];
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final ni in list) {
        final n = ni.name.toLowerCase();
        if (const ['rmnet', 'ccmni', 'tun', 'dummy', 'v4-', 'clat', 'ppp', 'ipsec']
            .any(n.startsWith)) {
          continue;
        }
        final rank = n.startsWith('ap') ||
                n.startsWith('swlan') ||
                n.startsWith('softap')
            ? 0
            : n.startsWith('wlan')
                ? 1
                : 2;
        for (final a in ni.addresses) {
          if (a.isLoopback || a.isLinkLocal) continue;
          ranked.add(MapEntry(rank, a.address));
        }
      }
    } catch (_) {}
    ranked.sort((a, b) => a.key.compareTo(b.key));
    return [for (final e in ranked) e.value];
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      final path = req.uri.path;
      final read = req.method == 'GET' || req.method == 'HEAD';
      final isApk = apkShareable &&
          (path == '/app/$apkName' ||
              path == '/$apkName' ||
              path == '/xprs.apk');
      if (read && path == '/') {
        await _serveChat(req);
        return;
      } else if (read && apkShareable && (path == '/app' || path == '/app/')) {
        res.headers.contentType = ContentType.html;
        res.write(_page());
      } else if (read && isApk) {
        await _serveApk(req);
        return;
      } else if (path.startsWith('/api/') && _api != null) {
        await _serveApi(req);
        return;
      } else {
        res.statusCode = HttpStatus.notFound;
      }
      await res.close();
    } catch (_) {
      try {
        await res.close();
      } catch (_) {}
    }
  }

  /// The web chat page, gzipped for a client that says it takes gzip, plain
  /// otherwise.
  Future<void> _serveChat(HttpRequest req) async {
    final res = req.response;
    final takesGzip = (req.headers.value(HttpHeaders.acceptEncodingHeader) ?? '')
        .toLowerCase()
        .contains('gzip');
    final body = takesGzip ? _chatGz! : _chatHtml!;
    res.headers
      ..contentType = ContentType('text', 'html', charset: 'utf-8')
      ..contentLength = body.length
      ..set(HttpHeaders.cacheControlHeader, 'no-cache');
    if (takesGzip) res.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
    if (req.method != 'HEAD') res.add(body);
    await res.close();
  }

  /// `/api/*` for the web chat: a small body at most, answered as JSON.
  Future<void> _serveApi(HttpRequest req) async {
    final res = req.response;
    var body = '';
    if (req.method == 'POST') {
      if (req.contentLength > 8192) {
        res.statusCode = HttpStatus.requestEntityTooLarge;
        await res.close();
        return;
      }
      body = await utf8.decoder.bind(req).join();
    }
    final reply = await _api!.handle(req.method, req.uri.path,
        req.uri.queryParameters, body,
        peer: req.connectionInfo?.remoteAddress.address ?? '');
    final bytes = utf8.encode(jsonEncode(reply.json));
    res
      ..statusCode = reply.status
      ..headers.contentType = ContentType.json
      ..headers.set('Access-Control-Allow-Origin', '*')
      ..headers.set(HttpHeaders.connectionHeader, 'close')
      ..contentLength = bytes.length
      ..add(bytes);
    await res.close();
  }

  Future<void> _serveApk(HttpRequest req) async {
    final res = req.response;
    final file = File(_apkPath);
    final size = await file.length();
    var start = 0;
    var end = size; // exclusive
    // One range, the shape a browser sends to resume ("bytes=N-" or "N-M").
    final range = req.headers.value(HttpHeaders.rangeHeader);
    final m = range == null
        ? null
        : RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(range.trim());
    if (m != null && (m[1]!.isNotEmpty || m[2]!.isNotEmpty)) {
      if (m[1]!.isEmpty) {
        start = size - int.parse(m[2]!).clamp(0, size);
      } else {
        start = int.parse(m[1]!);
        if (m[2]!.isNotEmpty) end = int.parse(m[2]!) + 1;
      }
      if (end > size) end = size;
      if (start >= end) {
        res.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        res.headers.set(HttpHeaders.contentRangeHeader, 'bytes */$size');
        await res.close();
        return;
      }
      res.statusCode = HttpStatus.partialContent;
      res.headers.set(
          HttpHeaders.contentRangeHeader, 'bytes $start-${end - 1}/$size');
    }
    res.headers
      ..contentType =
          ContentType('application', 'vnd.android.package-archive')
      ..contentLength = end - start
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set('Content-Disposition', 'attachment; filename="$apkName"');
    if (req.method == 'HEAD') {
      await res.close();
      return;
    }
    final peer = req.connectionInfo?.remoteAddress.address ?? '?';
    await file.openRead(start, end).pipe(res);
    if (end == size) {
      downloads.value++;
      LogService.instance.add('share-app: served $apkName to $peer');
    }
  }

  String _page() {
    final v = const HtmlEscape().convert(_version);
    final name = const HtmlEscape().convert(apkName);
    final abi = _abi.isEmpty
        ? ''
        : '<p class="s">Built for ${const HtmlEscape().convert(_abi)} phones.</p>';
    return '''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>XPRS $v</title>
<style>
body{font-family:sans-serif;margin:0;padding:24px 16px;background:#111;color:#eee;text-align:center}
a.b{display:inline-block;margin:24px 0;padding:16px 32px;border-radius:12px;background:#2e7d32;color:#fff;font-size:20px;text-decoration:none}
ol{text-align:left;max-width:420px;margin:0 auto;line-height:1.5}
.s{color:#aaa;font-size:14px}
</style></head><body>
<h1>XPRS</h1>
<p>Version $v</p>
<a class="b" href="/app/$name">Download</a>
$abi
<ol>
<li>Tap Download and wait for it to finish.</li>
<li>Open the downloaded file.</li>
<li>If Android asks, allow this browser to install apps, then go back and tap Install.</li>
</ol>
</body></html>''';
  }
}
