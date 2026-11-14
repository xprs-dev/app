/*
 * UpdatePage — the Updates panel (drawer → Updates).
 *
 * One status line (up to date / available / downloading / ready), one button
 * (Check now / Download / Install), the new version's notes, and the four
 * settings. Checking, downloading and the "ready" notice happen on their own
 * (UpdateService.start); this page only shows them and takes the person's
 * own requests. Disabled on web.
 */

import 'package:flutter/material.dart';

import '../services/update_service.dart';
import '../util/time_ago.dart';
import '../version.dart';
import '../services/i18n/core_i18n.dart';

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
    final pct = (_svc.progress.value * 100).round();

    final String line;
    if (ready) {
      line = tr('updates.state.ready', {'version': _svc.readyVersion});
    } else if (downloading) {
      final ph = _svc.phase.value;
      line = ph.isEmpty
          ? tr('updates.state.downloading', {'pct': pct})
          : tr('updates.downloading.phase', {'phase': ph, 'pct': pct});
    } else if (_svc.checking.value) {
      line = tr('updates.state.checking');
    } else if (newer) {
      line = tr(_svc.fdroidOnly ? 'updates.state.fdroid' : 'updates.state.available',
          {'version': sel!.version});
    } else {
      final last = _svc.lastCheck;
      line = last == null
          ? tr('updates.state.up_to_date')
          : tr('updates.state.checked', {'ago': timeAgo(last)});
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
        label: Text(tr('updates.download', {'version': sel!.version})),
        onPressed: () => _svc.download(sel),
      );
    } else {
      action = OutlinedButton.icon(
        icon: const Icon(Icons.refresh, size: 18),
        label: Text(tr('updates.check')),
        onPressed: _svc.checking.value ? null : _svc.checkForUpdates,
      );
    }

    return Card(
      elevation: 0,
      color: cs.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('XPRS ${_svc.currentVersion}',
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            Text(tr('updates.installed', {'build': kBuildNumber}),
                style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
            const SizedBox(height: 14),
            Text(line, style: text.bodyLarge),
            if (downloading) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                  value: _svc.progress.value > 0 ? _svc.progress.value : null),
            ],
            if (_svc.error != null) ...[
              const SizedBox(height: 8),
              Text(_svc.error!, style: TextStyle(color: cs.error)),
            ],
            if (action != null) ...[
              const SizedBox(height: 14),
              action,
            ],
          ],
        ),
      ),
    );
  }

  /// The notes of the version on offer: the one ready to install, or the
  /// newer one on the selected channel.
  List<Widget> _notes(BuildContext context) {
    final sel = _svc.selectedRelease;
    if (sel == null || !_svc.isNewer(sel)) return const [];
    final body = (sel.body ?? '').trim();
    if (body.isEmpty) return const [];
    final cs = Theme.of(context).colorScheme;
    return [
      const SizedBox(height: 20),
      Text(tr('updates.notes', {'version': sel.version}),
          style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: cs.primary, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      SelectableText(body,
          style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant)),
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
