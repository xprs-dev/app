import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../platform/platform.dart' as platform;
import '../services/android_permissions_service.dart';
import '../services/share_app_service.dart';
import '../version.dart';

/// Drawer -> Share: let a nearby phone chat with this one, and give it the app.
///
/// The phone serves, over HTTP on the local network (ShareAppService), the web
/// chat at `/` (any browser, nothing to install) and, when this copy can be
/// handed on, its own APK under `/app` (the chat links to it). The other phone
/// joins the same network, by scanning the hotspot QR when there is no Wi-Fi
/// the two have in common, then scans the chat QR. No internet, store or cable
/// involved.
class ShareAppPage extends StatefulWidget {
  const ShareAppPage({super.key});

  @override
  State<ShareAppPage> createState() => _ShareAppPageState();
}

class _ShareAppPageState extends State<ShareAppPage>
    with WidgetsBindingObserver {
  final _svc = ShareAppService.instance;

  ShareApkInfo? _apk;
  bool _loading = true;
  String? _fatal;

  ShareHotspot? _hotspot;
  bool _hotspotBusy = false;
  String? _hotspotError;

  List<String> _addrs = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _svc.hotspotUp.addListener(_onHotspotChanged);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _svc.hotspotUp.removeListener(_onHotspotChanged);
    // Sharing keeps running after the page closes (the person put the phone
    // down and the other one is chatting); "Stop sharing" ends it.
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from system settings, where the user may have switched on their
    // own hotspot or joined a Wi-Fi.
    if (state == AppLifecycleState.resumed) _refreshAddresses();
  }

  void _onHotspotChanged() {
    if (!_svc.hotspotUp.value && _hotspot != null && mounted) {
      setState(() => _hotspot = null);
      _refreshAddresses();
    }
  }

  Future<void> _boot() async {
    try {
      final apk = await _svc.apkInfo();
      if (apk == null) {
        setState(() {
          _loading = false;
          _fatal = 'Sharing works on Android only.';
        });
        return;
      }
      // The chat does not need the APK: a copy installed from a store in
      // pieces cannot be handed on, and can still host the chat.
      await _svc.start(
          apkPath: apk.shareable ? apk.path : '',
          version: kAppVersion,
          abi: apk.abi);
      final addrs = await _svc.localAddresses();
      if (!mounted) return;
      setState(() {
        _hotspot = _svc.hotspot;
        _apk = apk;
        _addrs = addrs;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _fatal = 'Could not start sharing: $e';
      });
    }
  }

  Future<void> _refreshAddresses() async {
    final addrs = await _svc.localAddresses();
    if (mounted) setState(() => _addrs = addrs);
  }

  /// The hotspot needs NEARBY_WIFI_DEVICES on Android 13+, and location (the
  /// permission and the system switch) below that. The intro asked for both,
  /// but either can have been revoked since.
  Future<bool> _ensureHotspotPermission() async {
    final sdk = await platform.androidSdkInt();
    if (sdk >= 33) {
      return (await Permission.nearbyWifiDevices.request()).isGranted;
    }
    if (!(await Permission.locationWhenInUse.request()).isGranted) return false;
    return AndroidPermissionsService.instance.locationServicesOn();
  }

  Future<void> _startHotspot() async {
    setState(() {
      _hotspotBusy = true;
      _hotspotError = null;
    });
    try {
      if (!await _ensureHotspotPermission()) {
        throw const ShareAppException('permission');
      }
      final before = _addrs.toSet();
      final h = await _svc.startHotspot();
      if (!mounted) return;
      setState(() => _hotspot = h);
      // The hotspot interface gets its address a moment after it is up.
      for (var i = 0; i < 10 && mounted; i++) {
        final addrs = await _svc.localAddresses();
        if (!mounted) return;
        setState(() => _addrs = addrs);
        if (addrs.any((a) => !before.contains(a))) break;
        await Future<void>.delayed(const Duration(milliseconds: 600));
      }
    } on ShareAppException catch (e) {
      if (mounted) setState(() => _hotspotError = _hotspotMessage(e.code));
    } finally {
      if (mounted) setState(() => _hotspotBusy = false);
    }
  }

  Future<void> _stopHotspot() async {
    await _svc.stopHotspot();
    if (!mounted) return;
    setState(() => _hotspot = null);
    _refreshAddresses();
  }

  String _hotspotMessage(String code) {
    switch (code) {
      case 'unsupported':
        return 'This phone cannot create a hotspot for an app (it needs '
            'Android 8 or newer).';
      case 'incompatible_mode':
        return 'Your phone\'s own hotspot is on, so the app cannot start '
            'one. Use that instead: have the other phone join it.';
      case 'tethering_disallowed':
        return 'Hotspots are switched off on this phone by its owner or '
            'carrier.';
      case 'permission':
        return 'The app needs the Nearby devices (or Location) permission '
            'to create a hotspot.';
      default:
        return 'The hotspot did not start.';
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Share'),
        actions: [
          if (_fatal == null && !_loading)
            IconButton(
              tooltip: 'Stop sharing',
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: () async {
                await _svc.stopSharing();
                if (mounted) Navigator.of(context).maybePop();
              },
            ),
          if (_fatal == null && !_loading)
            IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: _refreshAddresses,
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: _fatal != null
                  ? [_card(cs, _text(cs, _fatal!))]
                  : [
                      Text(
                        'Let a phone next to you chat with this one from its '
                        'browser, and give it the app. This phone keeps '
                        'serving both until you stop sharing; no internet is '
                        'needed.',
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(height: 20),
                      _header(context, '1. Same network'),
                      _card(cs, _networkStep(cs)),
                      const SizedBox(height: 20),
                      _header(context, '2. Web chat'),
                      _card(cs, _chatStep(cs)),
                      if (_svc.apkShareable) ...[
                        const SizedBox(height: 20),
                        _header(context, '3. The app'),
                        _card(cs, _appStep(cs)),
                      ],
                    ],
            ),
    );
  }

  Widget _networkStep(ColorScheme cs) {
    final h = _hotspot;
    if (h != null) {
      return Column(children: [
        _text(cs,
            'On the other phone, scan this with the camera to join the '
            'hotspot, or join it by hand:'),
        _qr(wifiQr(h)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SelectableText(
            'Network: ${h.ssid}\n'
            '${h.security == 'nopass' ? 'No password' : 'Password: ${h.psk}'}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16),
          ),
        ),
        TextButton.icon(
          onPressed: _stopHotspot,
          icon: const Icon(Icons.wifi_off),
          label: const Text('Stop hotspot'),
        ),
        const SizedBox(height: 8),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _text(cs,
            'Both phones on the same Wi-Fi already? Go to step 2. Otherwise '
            'this phone can make a private hotspot for the other to join.'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: FilledButton.icon(
            onPressed: _hotspotBusy ? null : _startHotspot,
            icon: _hotspotBusy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.wifi_tethering),
            label: const Text('Create hotspot'),
          ),
        ),
        if (_hotspotError != null) ...[
          _text(cs, _hotspotError!, color: cs.error),
          _text(cs,
              'You can also switch on the hotspot in this phone\'s system '
              'settings, have the other phone join it, and come back here.'),
        ],
      ],
    );
  }

  Widget _chatStep(ColorScheme cs) {
    if (_addrs.isEmpty) {
      return _text(cs,
          'This phone is not on any Wi-Fi or hotspot yet. Finish step 1, '
          'then tap Refresh.');
    }
    final url = 'http://${_addrs.first}:${_svc.port}/';
    return Column(children: [
      _text(cs,
          'On the other phone, scan this with the camera and open the link '
          '(or type it into the browser):'),
      _qr(url),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: SelectableText(url,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16)),
      ),
      if (_addrs.length > 1)
        _text(
            cs,
            'Not loading? Try: '
            '${_addrs.skip(1).map((a) => 'http://$a:${_svc.port}/').join('  ')}',
            small: true),
      ValueListenableBuilder<int>(
        valueListenable: _svc.visitorCount,
        builder: (_, n, _) => _text(
            cs,
            n == 0
                ? 'Waiting for a visitor'
                : n == 1
                    ? 'One visitor'
                    : '$n visitors',
            small: true),
      ),
    ]);
  }

  Widget _appStep(ColorScheme cs) {
    final apk = _apk;
    final mb = apk == null ? '' : ' (${(apk.size / 1e6).toStringAsFixed(0)} MB)';
    if (_addrs.isEmpty) {
      return _text(cs, 'Finish step 1 first.');
    }
    final url = 'http://${_addrs.first}:${_svc.port}/app';
    return Column(children: [
      _text(cs,
          'The chat page links to it. To skip the chat, scan this and tap '
          'Download$mb, then open the file; if Android asks, allow the '
          'browser to install apps and tap Install.'),
      _qr(url),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: SelectableText(url,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16)),
      ),
      ValueListenableBuilder<int>(
        valueListenable: _svc.downloads,
        builder: (_, n, _) => _text(
            cs,
            n == 0
                ? 'Waiting for a download'
                : n == 1
                    ? 'Downloaded once'
                    : 'Downloaded $n times',
            small: true),
      ),
      if (apk != null && apk.abi.isNotEmpty)
        _text(
            cs,
            'This copy is built for ${apk.abi} phones; a much older phone '
            'may refuse it.',
            small: true),
    ]);
  }

  Widget _qr(String data) => Padding(
        padding: const EdgeInsets.all(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
          ),
          child: QrImageView(
            data: data,
            size: 220,
            backgroundColor: Colors.white,
            // ignore: deprecated_member_use
            foregroundColor: Colors.black,
          ),
        ),
      );

  Widget _text(ColorScheme cs, String s, {Color? color, bool small = false}) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Text(
          s,
          style: TextStyle(
            color: color ?? (small ? cs.onSurfaceVariant : null),
            fontSize: small ? 13 : null,
          ),
        ),
      );

  Widget _header(BuildContext context, String s) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(s,
            style: Theme.of(context)
                .textTheme
                .titleSmall
                ?.copyWith(fontWeight: FontWeight.w700)),
      );

  Widget _card(ColorScheme cs, Widget child) => Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        color: cs.surfaceContainerLow,
        child: child,
      );
}
