/*
 * UpdatePage — the Updates panel (drawer → Updates).
 *
 * One card about the next version (up to date / available / downloading /
 * ready to install) with one button, the version that runs under it, the new
 * version's notes as formatted text, and the settings. Checking, downloading and the "ready" notice happen on their own
 * (UpdateService.start); this page only shows them and takes the person's
 * own requests. Disabled on web.
 */

import 'package:flutter/material.dart';

import '../services/update_service.dart';
import '../util/time_ago.dart';
import '../version.dart';
import '../services/i18n/core_i18n.dart';
import '../wapp/geoui/widgets/xprs_md_text.dart';

class UpdatePage extends StatefulWidget {
  const UpdatePage({super.key});

  @override
  State<UpdatePage> createState() => _UpdatePageState();
}

class _UpdatePageState extends State<UpdatePage> {
  final _svc = UpdateService.instance;

  @override
  void initState() {
    super.initState();
    _svc.pageOpen = true;
    _init();
  }

  @override
  void dispose() {
    _svc.pageOpen = false;
    super.dispose();
  }

  Future<void> _init() async {
    await _svc.load();
    if (mounted) setState(() {});
    if (!_svc.supported) return;
    // Re-attach to a download still running (or finished) in the background,
    // then look for a newer release.
    await _svc.resumeActiveDownload();
    await _svc.checkForUpdates();
    if (mounted) setState(() {});
  }

  Future<void> _set(Future<void> Function() change, {bool recheck = false}) async {
    await change();
    if (mounted) setState(() {});
    if (recheck) await _svc.checkForUpdates();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('updates.title'))),
      body: !_svc.supported
          ? const _WebNotice()
          : AnimatedBuilder(
              animation: Listenable.merge([
                _svc.status,
                _svc.checking,
                _svc.progress,
                _svc.phase,
                _svc.errorNote,
                _svc.stable,
                _svc.beta,
                _svc.fdroid,
                _svc.downloadingVersion,
              ]),
              builder: (context, _) => ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  _statusCard(context),
                  ..._notes(context),
                  const SizedBox(height: 24),
                  ..._settings(context),
                ],
              ),
            ),
    );
  }

  /// The card on top says what is happening with the NEXT version: its
  /// headline names the version being offered, fetched or waiting to be
  /// installed. What runs now is a quiet line under the card, so "1.10.0"
  /// never sits above "Downloading" as if the old version were coming.
  Widget _statusCard(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final st = _svc.status.value;
    final sel = _svc.selectedRelease;
    final newer = _svc.isNewer(sel);
    final ready = st == UpdateStatus.downloaded &&
        _svc.readyVersion != null &&
        !_svc.fdroidOnly;
    final downloading = st == UpdateStatus.downloading;
    final coming = _svc.downloadingVersion.value ?? sel?.version ?? '';
    final pct = (_svc.progress.value * 100).round();
    final phase = _svc.phase.value;
    // Looking for a copy (no bytes moving yet): the bar shows activity, not 0%.
    final searching = downloading && _svc.progress.value <= 0;

    final IconData icon;
    final String title;
    String? sub;
    if (ready) {
      icon = Icons.task_alt;
      title = tr('updates.hero.ready', {'version': _svc.readyVersion});
      sub = tr('updates.hero.ready.sub');
    } else if (downloading) {
      icon = Icons.downloading;
      title = tr('updates.hero.downloading', {'version': coming});
      sub = null; // the progress row says it
    } else if (_svc.checking.value) {
      icon = Icons.sync;
      title = tr('updates.hero.checking');
    } else if (newer) {
      icon = Icons.new_releases_outlined;
      title = tr('updates.hero.available', {'version': sel!.version});
      sub = _svc.fdroidOnly
          ? tr('updates.hero.available.fdroid')
          : _svc.autoUpdate
              ? tr(_svc.overMetered || !_svc.fdroidAvailable
                  ? 'updates.hero.available.auto'
                  : 'updates.hero.available.auto_wifi')
              : null;
    } else {
      icon = Icons.verified_outlined;
      title = tr('updates.hero.up_to_date');
      final last = _svc.lastCheck;
      sub = last == null ? null : tr('updates.checked', {'ago': timeAgo(last)});
    }

    Widget? action;
    if (ready) {
      action = FilledButton.icon(
        icon: const Icon(Icons.system_update_alt, size: 18),
        label: Text(tr('updates.install', {'version': _svc.readyVersion})),
        onPressed: () => _svc.install(sel),
      );
    } else if (downloading) {
      action = null;
    } else if (newer && _svc.fdroidOnly) {
      action = FilledButton.icon(
        icon: const Icon(Icons.storefront_outlined, size: 18),
        label: Text(tr('updates.fdroid.update')),
        onPressed: _svc.openFdroid,
      );
    } else if (newer) {
      action = FilledButton.icon(
        icon: const Icon(Icons.download, size: 18),
        label: Text(tr('updates.download.now')),
        onPressed: () => _svc.download(sel!),
      );
    } else {
      action = OutlinedButton.icon(
        icon: const Icon(Icons.refresh, size: 18),
        label: Text(tr('updates.check')),
        onPressed: _svc.checking.value ? null : _svc.checkForUpdates,
      );
    }

    final card = Card(
      elevation: 0,
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: cs.surfaceContainerHighest,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, size: 24, color: cs.onSurface),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: text.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700, height: 1.2)),
                      if (sub != null) ...[
                        const SizedBox(height: 4),
                        Text(sub,
                            style: text.bodyMedium
                                ?.copyWith(color: cs.onSurfaceVariant)),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            if (downloading) ...[
              const SizedBox(height: 18),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  minHeight: 6,
                  value: searching ? null : _svc.progress.value,
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: Text(
                      phase.isNotEmpty
                          ? phase
                          : tr('updates.phase.downloading'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant)),
                ),
                if (!searching)
                  Text('$pct%',
                      style: text.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          fontFeatures: const [FontFeature.tabularFigures()])),
              ]),
            ],
            if (_svc.error != null) ...[
              const SizedBox(height: 12),
              Text(_svc.error!,
                  style: text.bodySmall?.copyWith(color: cs.error)),
            ],
            if (action != null) ...[
              const SizedBox(height: 18),
              SizedBox(width: double.infinity, child: action),
            ],
          ],
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        card,
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 10, 4, 0),
          child: Text(
            tr('updates.installed.line',
                {'version': _svc.currentVersion, 'build': kBuildNumber}),
            style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
          ),
        ),
      ],
    );
  }

  /// The notes of the version on offer, drawn as the formatted text they are
  /// written in (headings, lists, links that open).
  List<Widget> _notes(BuildContext context) {
    final sel = _svc.selectedRelease;
    if (sel == null || !_svc.isNewer(sel)) return const [];
    final body = (sel.body ?? '').trim();
    if (body.isEmpty) return const [];
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return [
      const SizedBox(height: 28),
      Row(children: [
        Expanded(
          child: Text(tr('updates.notes', {'version': sel.version}),
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ),
        if (sel.isPrerelease)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              border: Border.all(color: cs.outline),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(tr('updates.beta.badge'),
                style: text.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
          ),
      ]),
      const SizedBox(height: 10),
      XprsMdText(
        body,
        style: text.bodyMedium!.copyWith(color: cs.onSurface, height: 1.45),
        linkColor: cs.primary,
        mutedColor: cs.onSurfaceVariant,
      ),
    ];
  }

  List<Widget> _settings(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final self = !_svc.fdroidOnly;
    return [
      Text(tr('common.settings'),
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: cs.onSurfaceVariant, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      if (self)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('updates.auto.title')),
          subtitle: Text(tr('updates.auto.desc')),
          value: _svc.autoUpdate,
          onChanged: (v) => _set(() => _svc.setAutoUpdate(v)),
        ),
      if (self && _svc.fdroidAvailable)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('updates.metered.title')),
          value: _svc.overMetered,
          onChanged: _svc.autoUpdate
              ? (v) => _set(() => _svc.setOverMetered(v))
              : null,
        ),
      if (self)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('updates.beta.title')),
          value: _svc.betaEnabled,
          onChanged: (v) =>
              _set(() => _svc.setBetaEnabled(v), recheck: true),
        ),
      // F-Droid ships this same APK, so either updater can install over the
      // other; this decides which one the phone listens to.
      if (_svc.fdroidAvailable)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr('updates.fdroid_only.title')),
          subtitle: Text(tr('updates.fdroid_only.desc')),
          value: _svc.fdroidOnly,
          onChanged: (v) => _set(() => _svc.setFdroidOnly(v), recheck: true),
        ),
    ];
  }
}

class _WebNotice extends StatelessWidget {
  const _WebNotice();
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            tr('updates.web_notice'),
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );
}
