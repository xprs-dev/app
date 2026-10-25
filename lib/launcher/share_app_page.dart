import 'dart:async';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../platform/platform.dart' as platform;
import '../services/android_permissions_service.dart';
import '../services/share_app_service.dart';
import '../version.dart';
import '../services/i18n/core_i18n.dart';

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
          _fatal = tr('share.android_only');
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
        _fatal = tr('share.start_failed', {'error': e});
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
        return tr('share.hotspot.unsupported');
      case 'incompatible_mode':
        return tr('share.hotspot.incompatible');
      case 'tethering_disallowed':
        return tr('share.hotspot.disallowed');
      case 'permission':
        return tr('share.hotspot.permission');
      default:
        return tr('share.hotspot.failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('share.title')),
        actions: [
          if (_fatal == null && !_loading)
            IconButton(
              tooltip: tr('share.stop'),
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: () async {
                await _svc.stopSharing();
                if (mounted) Navigator.of(context).maybePop();
              },
            ),
          if (_fatal == null && !_loading)
            IconButton(
              tooltip: tr('common.refresh'),
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
                        tr('share.intro'),
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(height: 20),
                      _header(context, tr('share.step.network')),
                      _card(cs, _networkStep(cs)),
                      const SizedBox(height: 20),
                      _header(context, tr('share.step.chat')),
                      _card(cs, _chatStep(cs)),
                      if (_svc.apkShareable) ...[
                        const SizedBox(height: 20),
                        _header(context, tr('share.step.app')),
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
        _text(cs, tr('share.hotspot.scan')),
        _qr(wifiQr(h)),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: SelectableText(
            '${tr('share.hotspot.network', {'ssid': h.ssid})}\n'
            '${h.security == 'nopass' ? tr('share.hotspot.nopass') : tr('share.hotspot.password', {'psk': h.psk})}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16),
          ),
        ),
        TextButton.icon(
          onPressed: _stopHotspot,
          icon: const Icon(Icons.wifi_off),
          label: Text(tr('share.hotspot.stop')),
        ),
        const SizedBox(height: 8),
      ]);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _text(cs, tr('share.hotspot.offer')),
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
            label: Text(tr('share.hotspot.create')),
          ),
        ),
        if (_hotspotError != null) ...[
          _text(cs, _hotspotError!, color: cs.error),
          _text(cs, tr('share.hotspot.manual')),
        ],
      ],
    );
  }

  Widget _chatStep(ColorScheme cs) {
    if (_addrs.isEmpty) {
      return _text(cs, tr('share.chat.no_network'));
    }
    final url = 'http://${_addrs.first}:${_svc.port}/';
    return Column(children: [
      _text(cs, tr('share.chat.scan')),
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
            tr('share.chat.alternatives', {
              'urls': _addrs.skip(1).map((a) => 'http://$a:${_svc.port}/').join('  ')
            }),
            small: true),
      ValueListenableBuilder<int>(
        valueListenable: _svc.visitorCount,
        builder: (_, n, _) => _text(
            cs,
            n == 0 ? tr('share.visitors.none') : trn('share.visitors', n),
            small: true),
      ),
    ]);
  }

  Widget _appStep(ColorScheme cs) {
    final apk = _apk;
    final mb = apk == null ? '' : ' (${(apk.size / 1e6).toStringAsFixed(0)} MB)';
    if (_addrs.isEmpty) {
      return _text(cs, tr('share.app.finish_first'));
    }
    final url = 'http://${_addrs.first}:${_svc.port}/app';
    return Column(children: [
      _text(cs, tr('share.app.how', {'mb': mb})),
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
            n == 0 ? tr('share.downloads.none') : trn('share.downloads', n),
            small: true),
      ),
      if (apk != null && apk.abi.isNotEmpty)
        _text(
            cs,
            tr('share.app.abi', {'abi': apk.abi}),
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
