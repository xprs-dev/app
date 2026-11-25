import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../platform/platform.dart' as platform;
import '../services/i18n/core_i18n.dart';
import '../services/share_app_service.dart';
import '../services/share_library.dart';
import '../services/update_models.dart';

/// Drawer -> Share: the web portal, and the installers it hands out.
///
/// The portal (ShareAppService) is an HTTP server on the local network: the
/// web chat at `/` for any browser, nothing to install, and `/app` with the
/// installers. Its switch is the first thing on the page because it is a
/// state the person leaves on, so the phone or desktop behaves as a station
/// for whoever joins its network, and it stays on after the page, the app's
/// window, and a reboot.
///
/// A device with no network in common with the visitor uses the system
/// hotspot (Android), which the person names, sees and leaves on; the app
/// makes no hotspot of its own (ShareBridge.kt says why).
class ShareAppPage extends StatefulWidget {
  const ShareAppPage({super.key});

  @override
  State<ShareAppPage> createState() => _ShareAppPageState();
}

class _ShareAppPageState extends State<ShareAppPage>
    with WidgetsBindingObserver {
  final _svc = ShareAppService.instance;
  final _lib = ShareLibrary.instance;
  final bool _android = platform.platformName() == 'android';

  /// This copy can be handed on as one file (known before the portal runs).
  bool _selfShareable = false;
  bool _loading = true;
  bool _switching = false;
  String? _fatal;
  List<String> _addrs = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Back from the hotspot screen or the system's Wi-Fi settings.
    if (state == AppLifecycleState.resumed) _refreshAddresses();
  }

  Future<void> _boot() async {
    try {
      await _svc.restore();
      await _lib.load();
      final apk = await _svc.apkInfo();
      final addrs = await _svc.localAddresses();
      if (!mounted) return;
      setState(() {
        _selfShareable = apk?.shareable ?? false;
        _addrs = addrs;
        _loading = false;
      });
      // Sizes for the Add buttons: the ~1 KB feed, once per visit.
      unawaited(_lib.refreshRelease());
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
    // The page may have opened with no internet (this phone's hotspot on, so
    // its Wi-Fi off); a network that came back can answer the feed now.
    if (_lib.release.value == null) unawaited(_lib.refreshRelease());
  }

  Future<void> _setPortal(bool on) async {
    setState(() => _switching = true);
    try {
      await _svc.setPortal(on);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr('share.start_failed', {'error': e}))));
      }
    }
    await _refreshAddresses();
    if (mounted) setState(() => _switching = false);
  }

  Future<void> _add(UpdatePlatform p) async {
    final why = await _lib.add(p);
    if (why == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(why == 'release'
            ? tr('share.installers.no_release')
            : tr('share.installers.failed', {'os': _osName(p)}))));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(tr('share.title'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: _fatal != null
                  ? [_card(cs, _text(cs, _fatal!))]
                  : [
                      _card(cs, _portalSwitch(cs)),
                      // The library too: an installer added below shows up
                      // in "Install the app" at once.
                      ListenableBuilder(
                        listenable: Listenable.merge([_svc.portal, _lib.files]),
                        builder: (context, _) => _svc.portal.value
                            ? Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: _portalOn(context, cs))
                            : const SizedBox.shrink(),
                      ),
                      const SizedBox(height: 20),
                      _header(context, tr('share.installers')),
                      _card(cs, _installers(cs)),
                    ],
            ),
    );
  }

  Widget _portalSwitch(ColorScheme cs) => ValueListenableBuilder<bool>(
        valueListenable: _svc.portal,
        builder: (_, on, _) => SwitchListTile(
          value: on,
          onChanged: _switching ? null : _setPortal,
          secondary: Icon(on ? Icons.wifi_tethering : Icons.portable_wifi_off,
              color: on ? cs.primary : cs.onSurfaceVariant),
          title: Text(tr('share.portal'),
              style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Text(on ? tr('share.portal.on') : tr('share.portal.off')),
        ),
      );

  List<Widget> _portalOn(BuildContext context, ColorScheme cs) {
    if (_addrs.isEmpty) {
      return [
        const SizedBox(height: 12),
        _card(
            cs,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              _text(cs, tr('share.no_network')),
              _networkHint(cs),
            ])),
      ];
    }
    final base = 'http://${_addrs.first}:${_svc.port}';
    final files = _svc.files;
    return [
      const SizedBox(height: 20),
      _header(context, tr('share.chat')),
      _card(
          cs,
          Column(children: [
            _qr('$base/'),
            _url('$base/'),
            if (_addrs.length > 1)
              _text(
                  cs,
                  tr('share.chat.alternatives', {
                    'urls': _addrs
                        .skip(1)
                        .map((a) => 'http://$a:${_svc.port}/')
                        .join('  ')
                  }),
                  small: true),
            ValueListenableBuilder<int>(
              valueListenable: _svc.visitorCount,
              builder: (_, n, _) => _text(cs,
                  n == 0 ? tr('share.visitors.none') : trn('share.visitors', n),
                  small: true),
            ),
            _networkHint(cs),
          ])),
      if (files.isNotEmpty) ...[
        const SizedBox(height: 20),
        _header(context, tr('share.install')),
        _card(
            cs,
            Column(children: [
              _qr('$base/app'),
              _url('$base/app'),
              ValueListenableBuilder<int>(
                valueListenable: _svc.downloads,
                builder: (_, n, _) => _text(
                    cs,
                    n == 0
                        ? tr('share.downloads.none')
                        : trn('share.downloads', n),
                    small: true),
              ),
            ])),
      ],
    ];
  }

  /// How the other device gets onto this one's network.
  Widget _networkHint(ColorScheme cs) {
    if (!_android) return _text(cs, tr('share.same_network'), small: true);
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
      child: Column(children: [
        _text(cs, tr('share.hotspot.hint'), small: true),
        OutlinedButton.icon(
          onPressed: () async {
            if (!await _svc.openHotspotSettings() && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(tr('share.hotspot.none'))));
            }
          },
          icon: const Icon(Icons.wifi_tethering),
          label: Text(tr('share.hotspot.open')),
        ),
      ]),
    );
  }

  Widget _installers(ColorScheme cs) => ValueListenableBuilder<List<ShareEntry>>(
        valueListenable: _lib.files,
        builder: (_, _, _) => ValueListenableBuilder<Map<UpdatePlatform, double>>(
          valueListenable: _lib.busy,
          builder: (_, busy, _) => ValueListenableBuilder<ReleaseInfo?>(
            valueListenable: _lib.release,
            builder: (_, release, _) => Column(children: [
              for (final p in kSharePlatforms)
                _installerRow(cs, p, busy[p], release),
            ]),
          ),
        ),
      );

  Widget _installerRow(
      ColorScheme cs, UpdatePlatform p, double? progress, ReleaseInfo? release) {
    final self =
        p == UpdatePlatform.android && (_selfShareable || _svc.apkShareable);
    ShareEntry? held;
    for (final e in _lib.files.value) {
      if (e.platform == p) held = e;
    }
    // What the feed offers for this system, by name (macOS has no build yet).
    ReleaseAsset? offered;
    if (release != null) {
      for (final a in release.assets) {
        if (sharePlatformOf(a.name) == p) offered = a;
      }
    }
    final String subtitle;
    Widget? trailing;
    if (self) {
      subtitle = tr('share.installers.self');
    } else if (progress != null) {
      subtitle = tr('share.installers.adding');
      trailing = SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(
              strokeWidth: 2.5, value: progress < 0 ? null : progress));
    } else if (held != null) {
      subtitle = tr('share.installers.added', {'size': _mb(held.size)});
      trailing = IconButton(
        tooltip: tr('share.installers.remove'),
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _lib.remove(p),
      );
    } else {
      subtitle = release != null && offered == null
          ? tr('share.installers.none')
          : offered != null
              ? _mb(offered.size)
              : '';
      trailing = release != null && offered == null
          ? null
          : TextButton(
              onPressed: () => _add(p), child: Text(tr('share.installers.add')));
    }
    return ListTile(
      leading: Icon(_osIcon(p), color: cs.onSurfaceVariant),
      title: Text(_osName(p)),
      subtitle: subtitle.isEmpty ? null : Text(subtitle),
      trailing: trailing,
    );
  }

  static String _mb(int bytes) => '${(bytes / 1e6).toStringAsFixed(0)} MB';

  static String _osName(UpdatePlatform p) => switch (p) {
        UpdatePlatform.android => 'Android',
        UpdatePlatform.windows => 'Windows',
        UpdatePlatform.linux => 'Linux',
        UpdatePlatform.macos => 'macOS',
        UpdatePlatform.unknown => '',
      };

  static IconData _osIcon(UpdatePlatform p) => switch (p) {
        UpdatePlatform.android => Icons.android,
        UpdatePlatform.windows => Icons.desktop_windows_outlined,
        UpdatePlatform.linux => Icons.computer_outlined,
        UpdatePlatform.macos => Icons.laptop_mac_outlined,
        UpdatePlatform.unknown => Icons.help_outline,
      };

  Widget _url(String url) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
        child: SelectableText(url,
            textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
      );

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
          textAlign: small ? TextAlign.center : null,
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
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
        ),
        color: cs.surfaceContainerLow,
        child: child,
      );
}
