/*
 * Deep links — Android only (for now).
 *
 * Tapping a https://xprs.dev/circle/<key> link (or the xprs://circle/<key>
 * fallback) opens XPRS straight on the circles wapp's "apply to join" flow.
 * MainActivity captures the launch URI and pushes later ones over the
 * `com.xprs.app/links` method channel; we resolve the circles wapp and
 * push its WappPage with an `apply_url` initial command carrying the full link.
 *
 * The wapp parses the circle id back out of the URL (full key, authoritative) so
 * a brand-new applicant can join a circle they've never seen. The short code in
 * the path is human shorthand only and needs a directory to resolve — the link
 * always carries the full key.
 */
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../launcher/launcher.dart' show rootNavigatorKey;
import '../profile/storage_paths.dart';
import '../wapp/wapp_open.dart';
import '../wapp/wapp_page.dart';
import 'desktop_link.dart';
import 'log_service.dart';

class DeepLinkService with WidgetsBindingObserver {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  static const _channel = MethodChannel('com.xprs.app/links');

  bool _started = false;

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Wire the channel and process the link this session was launched with.
  /// Safe to call once after the navigator is live.
  /// The link this launch was started with, on the desktop (main sets it).
  String? launchLink;

  Future<void> start() async {
    if (_started) return;
    if (!_supported && desktopLinksSupported) {
      // Linux: the link of this launch, and those of later launches, which
      // hand theirs over and exit (desktop_link.dart).
      _started = true;
      await listenDesktopLinks('${xprsRootStorage().basePath}/link.sock',
          (link) => unawaited(_handle(link)));
      final first = launchLink;
      launchLink = null;
      if (first != null) await _handle(first);
      return;
    }
    if (!_supported) return;
    _started = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onLink') {
        final link = call.arguments as String?;
        if (link != null) await _handle(link);
      }
      return null;
    });
    WidgetsBinding.instance.addObserver(this);
    await _pullLaunchLink();
  }

  /// Ask the Activity for the link it was started with, once per link (the
  /// native side forgets it when it is read).
  ///
  /// Not only at boot. The engine outlives the Activity: it runs headless
  /// from boot, and Android starts a NEW Activity for a tapped notification
  /// when the old one is gone or sits in another task. That Activity keeps its
  /// link for whoever asks, and this service had already asked, at boot, an
  /// Activity that was not there: the tap opened the app on the launcher and
  /// the notification stayed unread. So it asks again each time the app comes
  /// to the front. One channel trip per resume, nothing while in the pocket.
  Future<void> _pullLaunchLink() async {
    try {
      final link = await _channel.invokeMethod<String>('getInitialLink');
      if (link != null && link.isNotEmpty) await _handle(link);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_pullLaunchLink());
  }

  Future<void> _handle(String url) async {
    LogService.instance.add('DeepLink: $url');
    final lower = url.toLowerCase();
    // xprs://open?wapp=<folder>&convo=<id>&view=<view> — a tapped Android
    // notification.
    // Same opener as the in-app notification center, so both taps land on the
    // same screen: the wapp, on the conversation when one is named.
    //
    // `xprs://` is still accepted. Links were shared under the old scheme —
    // circle invitations in chats and QR codes — and they outlive the rename.
    if (lower.startsWith('xprs://open') || lower.startsWith('xprs://open')) {
      final uri = Uri.tryParse(url);
      if (uri == null) return;
      await openNotificationTarget(
        uri.queryParameters['wapp'] ?? '',
        convo: uri.queryParameters['convo'],
        view: uri.queryParameters['view'],
        // Which notification was tapped (BgBridge.notify puts it there).
        notificationId: uri.queryParameters['n'],
        navigator: rootNavigatorKey.currentState,
      );
      return;
    }
    // A link to a group (xprs.dev/in/<x5 callsign>, xprs.dev/in/g/<name>,
    // or the same under xprs://in/): the chat, on that group. The chat wapp
    // follows a group it is asked to open and gives it a room, so somebody
    // who never heard of the group lands in it.
    final room = groupRoomOfLink(url);
    if (room != null) {
      final ok = await openWappByFolder('chat',
          convo: room, navigator: rootNavigatorKey.currentState);
      if (!ok) LogService.instance.add('DeepLink: no chat to open $room in');
      return;
    }
    final target = await _wappForLink(url);
    if (target == null) {
      LogService.instance
          .add('DeepLink: no installed wapp claims $url');
      return;
    }
    final nav = rootNavigatorKey.currentState;
    if (nav == null) {
      LogService.instance.add('DeepLink: no navigator');
      return;
    }
    final cmd = jsonEncodeCommand(url);
    await nav.push(MaterialPageRoute(
      builder: (_) => WappPage(
        wappDir: target.dir,
        title: target.title,
        initialCommand: cmd,
      ),
    ));
  }

  /// The chat room a group link names, or null when [url] is not one:
  /// `#X5ABCD` for `https://xprs.dev/in/x5abcd` and `xprs://in/x5abcd`,
  /// `#LISBOA` for `https://xprs.dev/in/g/lisboa` and `xprs://in/g/lisboa`.
  /// A station's address (`/in/x3ptzm`) is not a group: that is a page for a
  /// browser. The forms are the ones the web chat's Share link writes
  /// (portal chat_page.html `groupLink`).
  static String? groupRoomOfLink(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    final List<String> segs;
    if ((uri.scheme == 'https' || uri.scheme == 'http') &&
        uri.host.toLowerCase() == 'xprs.dev') {
      final p = uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (p.isEmpty || p.first.toLowerCase() != 'in') return null;
      segs = p.sublist(1);
    } else if (uri.scheme == 'xprs' && uri.host.toLowerCase() == 'in') {
      segs = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    } else {
      return null;
    }
    if (segs.length == 2 && segs[0].toLowerCase() == 'g') {
      final g = segs[1].toUpperCase();
      return RegExp(r'^[A-Z0-9][A-Z0-9_-]{0,15}$').hasMatch(g) ? '#$g' : null;
    }
    if (segs.length == 1) {
      final g = segs[0].toUpperCase();
      return RegExp(r'^X5[A-Z0-9]{1,6}$').hasMatch(g) ? '#$g' : null;
    }
    return null;
  }

  /// JSON the circles wapp understands: an `apply_url` command carrying the
  /// full link, from which it extracts the circle id and starts the join flow.
  static String jsonEncodeCommand(String url) =>
      '{"command":"apply_url","code":${_jsonString(url)}}';

  static String _jsonString(String s) {
    final b = StringBuffer('"');
    for (final r in s.runes) {
      switch (r) {
        case 0x22:
          b.write('\\"');
        case 0x5C:
          b.write('\\\\');
        case 0x0A:
          b.write('\\n');
        case 0x0D:
          b.write('\\r');
        case 0x09:
          b.write('\\t');
        default:
          if (r < 0x20) {
            b.write('\\u${r.toRadixString(16).padLeft(4, '0')}');
          } else {
            b.writeCharCode(r);
          }
      }
    }
    b.write('"');
    return b.toString();
  }

  /// The installed wapp that claims this link, or null.
  ///
  /// A wapp declares what it opens in its own manifest, the same way it
  /// declares file handlers and view intents:
  ///
  ///     "provides": { "links": ["/circle/", "xprs://circle"] }
  ///
  /// The core matches and routes; it does not know that circles exist. Naming
  /// a wapp here would put one application's routing table inside the core,
  /// and the next feature would add a second (docs/architecture.md §3).
  Future<_LinkTarget?> _wappForLink(String url) async {
    final lower = url.toLowerCase();
    final installed = installedAppsStorage();
    if (!await installed.directoryExists('')) return null;
    for (final e in await installed.listDirectory('')) {
      if (!e.isDirectory) continue;
      try {
        final pkg = wappPackageStorage(installed.getAbsolutePath(e.path));
        final m = await pkg.readJson('manifest.json');
        if (m == null) continue;
        final provides = m['provides'];
        final links = (provides is Map) ? provides['links'] : null;
        if (links is! List) continue;
        for (final raw in links) {
          final pat = raw.toString().trim().toLowerCase();
          if (pat.isEmpty || !lower.contains(pat)) continue;
          final title = (m['title'] ?? m['name'] ?? e.name).toString();
          return _LinkTarget(pkg.basePath, title);
        }
      } catch (_) {}
    }
    // Fallback for wapps installed before they declared `provides.links`:
    // match the link's own subject word against the wapp's identity —
    // "xprs://circle/…" -> a wapp called circles. Derived from the URL, so
    // the core still names no application (docs/architecture.md §3). Drops out
    // once installed copies carry the declaration.
    final subject = _linkSubject(lower);
    if (subject.isEmpty) return null;
    for (final e in await installed.listDirectory('')) {
      if (!e.isDirectory) continue;
      try {
        final pkg = wappPackageStorage(installed.getAbsolutePath(e.path));
        final m = await pkg.readJson('manifest.json');
        if (m == null) continue;
        final hay = '${m['id'] ?? ''} ${m['name'] ?? ''} ${m['title'] ?? ''} '
                '${e.name}'
            .toLowerCase();
        if (!hay.contains(subject)) continue;
        final title = (m['title'] ?? m['name'] ?? e.name).toString();
        return _LinkTarget(pkg.basePath, title);
      } catch (_) {}
    }
    return null;
  }
}

/// The word a link is about: the first path segment after the scheme or host
/// ("xprs://circle/ab12" and "https://x.y/circle/ab12" -> "circle"). The old
/// `xprs` scheme is still recognised; see _handle.
String _linkSubject(String lowerUrl) {
  final u = Uri.tryParse(lowerUrl);
  if (u == null) return '';
  final segs = [
    if (u.host.isNotEmpty && (u.scheme == 'xprs' || u.scheme == 'xprs')) u.host,
    ...u.pathSegments,
  ].where((s) => s.isNotEmpty).toList();
  return segs.isEmpty ? '' : segs.first;
}

/// An installed wapp that claims a link, and the title to show while it opens.
class _LinkTarget {
  const _LinkTarget(this.dir, this.title);
  final String dir;
  final String title;
}
