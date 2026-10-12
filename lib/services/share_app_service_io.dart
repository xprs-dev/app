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

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'log_service.dart';
import 'share_app_types.dart';

export 'share_app_types.dart';

class ShareAppService {
  ShareAppService._() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'hotspotStopped') hotspotUp.value = false;
    });
  }
  static final ShareAppService instance = ShareAppService._();

  /// Tried first so the URL is easy to type by hand; any free port otherwise.
  static const int preferredPort = 8642;

  static const _channel = MethodChannel('com.xprs.app/share');

  /// Completed APK transfers since the page opened.
  final ValueNotifier<int> downloads = ValueNotifier<int>(0);
  final ValueNotifier<bool> hotspotUp = ValueNotifier<bool>(false);

  HttpServer? _server;
  String _apkPath = '';
  String _version = '';
  String _abi = '';

  bool get running => _server != null;
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
      return ShareHotspot(
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
    try {
      await _channel.invokeMethod<void>('stopHotspot');
    } catch (_) {}
  }

  /// Start serving [apkPath]. Returns the port. [port] is for tests; the page
  /// leaves it null and gets [preferredPort] when it is free.
  Future<int> start({
    required String apkPath,
    required String version,
    String abi = '',
    int? port,
  }) async {
    _apkPath = apkPath;
    _version = version;
    _abi = abi;
    if (_server != null) return _server!.port;
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
    LogService.instance.add('share-app: serving on port ${server.port}');
    return server.port;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
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
      final isApk = path == '/$apkName' || path == '/xprs.apk';
      if ((req.method == 'GET' || req.method == 'HEAD') && path == '/') {
        res.headers.contentType = ContentType.html;
        res.write(_page());
      } else if ((req.method == 'GET' || req.method == 'HEAD') && isApk) {
        await _serveApk(req);
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
<a class="b" href="/$name">Download</a>
$abi
<ol>
<li>Tap Download and wait for it to finish.</li>
<li>Open the downloaded file.</li>
<li>If Android asks, allow this browser to install apps, then go back and tap Install.</li>
</ol>
</body></html>''';
  }
}
