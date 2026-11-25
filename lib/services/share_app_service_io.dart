/*
 * ShareAppService on native: the web portal. An HTTP server on the local
 * network that serves the web chat, and the installers this device can hand
 * on (its own APK on Android, plus ShareLibrary's files for other systems);
 * the channel to ShareBridge.kt for the APK path and the hotspot screen.
 *
 * The portal is a switch its owner leaves on or off (`share.portal`): on, it
 * outlives the page and the app's window, and comes back at boot, so a phone
 * left on a table behaves as a station for whoever joins its network.
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
import 'package:shared_preferences/shared_preferences.dart';

import 'background_service.dart';
import 'log_service.dart';
import 'share_app_types.dart';
import 'share_library.dart';
import 'update_models.dart';
import 'package:xprs_core/src/services/preferences_service.dart';
import 'package:xprs_core/src/services/station/station_host.dart';
import 'web_chat_api.dart';
import '../version.dart';
import '../wapp/android_foreground_service.dart';

export 'share_app_types.dart';
export 'share_library.dart' show ShareEntry, ShareLibrary;

class ShareAppService {
  ShareAppService._();
  static final ShareAppService instance = ShareAppService._();

  static const String _kPortal = 'share.portal';

  /// The portal switch as its owner left it; follows [setPortal].
  final ValueNotifier<bool> portal = ValueNotifier<bool>(false);

  /// Tried first so the URL is easy to type by hand; any free port otherwise.
  static const int preferredPort = 8642;

  static const _channel = MethodChannel('com.xprs.app/share');

  /// Completed installer downloads since the portal started.
  final ValueNotifier<int> downloads = ValueNotifier<int>(0);

  /// The web chat page, built in the `portal` repo and bundled as plain
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
  int _apkSize = 0;
  List<ShareEntry> Function() _library = _liveLibrary;
  static List<ShareEntry> _liveLibrary() => ShareLibrary.instance.files.value;

  bool get running => _server != null;

  /// Whether this copy can be handed on as one file.
  bool get apkShareable => _apkPath.isNotEmpty;

  /// Everything `/app` offers: this copy's APK first, when it can be handed
  /// on, then the library (its own APK only when this copy cannot be).
  List<ShareEntry> get files => [
        if (apkShareable)
          ShareEntry(
              platform: UpdatePlatform.android,
              name: apkName,
              path: _apkPath,
              size: _apkSize,
              self: true),
        for (final e in _library())
          if (!(apkShareable && e.platform == UpdatePlatform.android)) e,
      ];

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

  /// Open the system's hotspot screen (Android). False where there is none.
  Future<bool> openHotspotSettings() async {
    if (!Platform.isAndroid) return false;
    try {
      return await _channel.invokeMethod<bool>('openHotspotSettings') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Read the switch and, when it is on, start the portal. At boot
  /// ([hostBoot]) and when the page opens.
  Future<void> restore() async {
    final p = await SharedPreferences.getInstance();
    portal.value = p.getBool(_kPortal) ?? false;
    if (portal.value) await _startPortal();
  }

  /// The switch. On: serve now and at every boot until switched off.
  Future<void> setPortal(bool on) async {
    portal.value = on;
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kPortal, on);
    if (on) {
      await _startPortal();
    } else {
      await stop();
    }
  }

  Future<void> _startPortal() async {
    if (running) return;
    await ShareLibrary.instance.load();
    // The chat does not need the APK: a copy installed from a store in
    // pieces cannot be handed on, and can still host the chat.
    ShareApkInfo? apk;
    try {
      apk = await apkInfo();
    } catch (_) {}
    await start(
        apkPath: apk != null && apk.shareable ? apk.path : '',
        version: kAppVersion,
        abi: apk?.abi ?? '',
        apkSize: apk?.size ?? 0);
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
    int apkSize = 0,
    int? port,
    WebChatApi? api,
    Uint8List? chatPage,
    List<ShareEntry> Function()? library,
  }) async {
    _apkPath = apkPath;
    _library = library ?? _liveLibrary;
    _version = version;
    _abi = abi;
    _apkSize = apkSize;
    if (_server != null) return _server!.port;
    _api = api ?? _liveApi();
    // The owner administers this phone before the first visitor of its own
    // network (a hotspot guest) could claim it.
    if (api == null) await StationHost.instance.ensureOwner();
    visitorCount.value = 0;
    _api!.onVisitors = (n) => visitorCount.value = n;
    final html = _chatHtml = chatPage ??
        (await rootBundle.load(chatAsset)).buffer.asUint8List();
    // 80 KB deflated once per start, off the UI isolate (performance.md:
    // compression is worker work).
    _chatGz = await _gzipOffThread(html);
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

  /// Deflate [bytes] on a worker isolate. Static on purpose: a closure made
  /// inside an instance method captures `this`, and this service reaches the
  /// archive and its Timer, which no isolate message may carry -- Share failed
  /// with "object is unsendable ... _Timer" for exactly that reason.
  static Future<Uint8List> _gzipOffThread(Uint8List bytes) =>
      BackgroundService.runOffThread(
          () async => Uint8List.fromList(gzip.encode(bytes)));

  /// The API a visitor's browser gets, wired to the core: what it posts goes
  /// through the one receive door (as heard on the hotspot's network, `lan`,
  /// through the API), which the bridge and digipeater carry on under the
  /// owner's policy; what it reads is the archive's undirected rows.
  WebChatApi _liveApi() => StationHost.instance.api ??= stationWebChatApi(
        appPath: () => files.isEmpty ? null : '/app',
        store: PreferencesService.instanceSync?.store,
      );

  /// This phone as a station: the same API the hotspot page uses, answered
  /// over Reticulum links while its owner has said so (Settings). Its owner
  /// is made its administrator before anybody else can ask.
  Future<void> hostBoot() async {
    _liveApi();
    await StationHost.instance
        .serve(PreferencesService.instanceSync?.xprsHostStation ?? false);
    // The web portal, when its owner left it on.
    await restore();
  }

  static const String _holder = 'share';

  Future<void> stop() async {
    final s = _server;
    _server = null;
    unawaited(AndroidForegroundService.instance.release(_holder));
    if (s != null) {
      await s.close(force: true);
      LogService.instance.add('share-app: stopped');
    }
  }

  /// IPv4 addresses another device could reach us on, best first: a hotspot
  /// interface, then Wi-Fi, then wired, then anything else. Cellular,
  /// tunnels, VPNs and virtual bridges are left out: those are never on the
  /// same network as a device next to us.
  Future<List<String>> localAddresses() async {
    final ranked = <MapEntry<int, String>>[];
    try {
      final list = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final ni in list) {
        final rank = shareInterfaceRank(ni.name);
        if (rank == null) continue;
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
      final all = files;
      final file = read ? _fileFor(all, path) : null;
      if (read && path == '/') {
        await _serveChat(req);
        return;
      } else if (read && all.isNotEmpty && (path == '/app' || path == '/app/')) {
        res.headers.contentType = ContentType('text', 'html', charset: 'utf-8');
        res.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
        res.write(_page(all));
      } else if (file != null) {
        await _serveFile(req, file);
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
    Uint8List? raw;
    // A file by reference (API-HTTP.md) is bytes, up to the API's own cap.
    final isFile = req.uri.path.startsWith(WebChatApi.filePath);
    final cap = isFile ? _api!.fileMax : 8192;
    if (req.method == 'POST') {
      if (req.contentLength > cap) {
        res.statusCode = HttpStatus.requestEntityTooLarge;
        await res.close();
        return;
      }
      if (isFile) {
        final b = BytesBuilder(copy: false);
        await for (final c in req) {
          b.add(c);
          if (b.length > cap) {
            res.statusCode = HttpStatus.requestEntityTooLarge;
            await res.close();
            return;
          }
        }
        raw = b.takeBytes();
      } else {
        body = await utf8.decoder.bind(req).join();
      }
    }
    final reply = await _api!.handle(req.method, req.uri.path,
        req.uri.queryParameters, body,
        peer: req.connectionInfo?.remoteAddress.address ?? '', raw: raw);
    if (reply.bytes != null) {
      res.statusCode = reply.status;
      res.headers.set(HttpHeaders.contentTypeHeader, reply.contentType!);
      res.headers.set('Access-Control-Allow-Origin', '*');
      reply.headers.forEach(res.headers.set);
      res.headers.set(HttpHeaders.connectionHeader, 'close');
      res.contentLength = reply.bytes!.length;
      if (req.method != 'HEAD') res.add(reply.bytes!);
      await res.close();
      return;
    }
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

  /// The file [path] names: `/app/<name>`, and for this copy's APK the
  /// addresses already handed out (`/<name>`, `/xprs.apk`).
  ShareEntry? _fileFor(List<ShareEntry> all, String path) {
    for (final e in all) {
      if (path == '/app/${e.name}') return e;
      if (e.self && (path == '/${e.name}' || path == '/xprs.apk')) return e;
    }
    return null;
  }

  static ContentType _typeOf(String name) {
    final n = name.toLowerCase();
    if (n.endsWith('.apk')) {
      return ContentType('application', 'vnd.android.package-archive');
    }
    if (n.endsWith('.gz')) return ContentType('application', 'gzip');
    if (n.endsWith('.zip')) return ContentType('application', 'zip');
    return ContentType('application', 'octet-stream');
  }

  Future<void> _serveFile(HttpRequest req, ShareEntry entry) async {
    final res = req.response;
    final file = File(entry.path);

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
      ..contentType = _typeOf(entry.name)
      ..contentLength = end - start
      ..set(HttpHeaders.acceptRangesHeader, 'bytes')
      ..set('Content-Disposition', 'attachment; filename="${entry.name}"');
    if (req.method == 'HEAD') {
      await res.close();
      return;
    }
    final peer = req.connectionInfo?.remoteAddress.address ?? '?';
    await file.openRead(start, end).pipe(res);
    if (end == size) {
      downloads.value++;
      LogService.instance.add('share-app: served ${entry.name} to $peer');
    }
  }

  static const Map<UpdatePlatform, String> _labels = {
    UpdatePlatform.android: 'Android',
    UpdatePlatform.windows: 'Windows',
    UpdatePlatform.linux: 'Linux',
    UpdatePlatform.macos: 'macOS',
  };

  /// What to do with the file, per system, in a few words.
  static const Map<UpdatePlatform, String> _howTo = {
    UpdatePlatform.android:
        'Open the file. If asked, allow this browser to install apps.',
    UpdatePlatform.windows: 'Run the file and follow the installer.',
    UpdatePlatform.linux: 'Extract it and run ./xprs',
    UpdatePlatform.macos: 'Open the file and move XPRS to Applications.',
  };

  /// `/app`: one button per system. The visitor's own system goes first and
  /// stands out; the page's script decides that from the browser's own user
  /// agent, so the server stays a list of files.
  String _page(List<ShareEntry> all) {
    const esc = HtmlEscape();
    final v = esc.convert(_version);
    final rows = StringBuffer();
    for (final e in all) {
      final size =
          e.size > 0 ? ' · ${(e.size / 1e6).toStringAsFixed(0)} MB' : '';
      final abi = e.self && _abi.isNotEmpty ? ' · ${esc.convert(_abi)}' : '';
      rows.write('<div class="r" data-os="${e.platform.name}">'
          '<a class="b" href="/app/${esc.convert(e.name)}" download>'
          '${_labels[e.platform]}</a>'
          '<p class="s">${esc.convert(e.name)}$size$abi</p>'
          '<p class="s">${esc.convert(_howTo[e.platform]!)}</p></div>');
    }
    return '''<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>XPRS $v</title>
<style>
body{font-family:sans-serif;margin:0;padding:24px 16px;background:#111;color:#eee;text-align:center}
.r{margin:0 auto 20px;max-width:420px}
a.b{display:block;margin:0 0 6px;padding:14px;border-radius:12px;background:#333;color:#fff;font-size:20px;text-decoration:none}
.r.me a.b{background:#2e7d32}
.s{color:#aaa;font-size:14px;margin:2px 0}
</style></head><body>
<h1>XPRS</h1>
<p>Version $v</p>
<div id="l">$rows</div>
<script>
(function(){var u=navigator.userAgent,o=/Android/i.test(u)?'android':/Windows/i.test(u)?'windows':/Mac OS X|Macintosh/i.test(u)&&!/iPhone|iPad/i.test(u)?'macos':/Linux|X11/i.test(u)?'linux':'';
var l=document.getElementById('l'),m=l.querySelector('[data-os="'+o+'"]');if(m){m.className+=' me';l.insertBefore(m,l.firstChild);}})();
</script>
</body></html>''';
  }
}
