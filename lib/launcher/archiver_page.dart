// The Archiver: what this device keeps and serves for the network, and which
// archivers it relies on itself (XPRS.md section 12). A core function of the
// app, so a page of the app rather than a wapp; it replaced the Archive wapp.
//
// Every number comes from the core (xprsArchiveStatusJson, NodeRoleApi) and
// every change goes through one writer (applyArchiverSettings) shared with the
// remote API, so the page and `/api/xprs/archiver` cannot drift apart.
//
// Reads are cheap SQL counts and run when the page opens, after each change,
// on pull-to-refresh, and once a minute while the page is in front.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:xprs_core/src/services/social/node_role_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_names.dart';

import '../services/i18n/core_i18n.dart';
import '../services/preferences_service.dart';
import '../services/xprs/archiver_settings.dart';
import '../services/xprs/xprs_archive.dart';
import '../services/xprs/xprs_history_server.dart';
import '../services/xprs/xprs_station_policy.dart';

class ArchiverPage extends StatefulWidget {
  const ArchiverPage({super.key});

  /// The notification source a cleanup result is raised under; a tap on it
  /// opens this page (wapp_open.dart hostNotificationPages).
  static const String target = 'host:archiver';

  @override
  State<ArchiverPage> createState() => _ArchiverPageState();
}

class _ArchiverPageState extends State<ArchiverPage> {
  Map<String, dynamic> _arch = const {};
  Map<String, dynamic> _files = const {};
  Map<String, dynamic> _dir = const {};
  Timer? _tick;
  final _dial = TextEditingController();
  final _search = TextEditingController();
  List<Map<String, Object>> _found = const [];

  PreferencesService? get _prefs => PreferencesService.instanceSync;

  @override
  void initState() {
    super.initState();
    _dial.text = _prefs?.xprsDial ?? '';
    _refresh();
    // Foreground-only, once a minute: the counts move slowly and nobody is
    // looking once the page is closed (docs/performance.md 6.5).
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _dial.dispose();
    _search.dispose();
    super.dispose();
  }

  Map<String, dynamic> _decode(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map<String, dynamic> ? v : const {};
    } catch (_) {
      return const {};
    }
  }

  void _refresh() {
    final prefs = _prefs;
    if (prefs == null || !mounted) return;
    final archive = XprsArchive.instance;
    final claim = xprsServeClaim(
          public: prefs.xprsPublicArchiver,
          spoolReady: archive.ready,
          files: prefs.archiveQuotaGb > 0,
        ) ??
        '';
    setState(() {
      _arch = xprsArchiveStatusJson(
        public: prefs.xprsPublicArchiver,
        alwaysOn: prefs.xprsAlwaysOn,
        alwaysOnStored: prefs.xprsAlwaysOnStored,
        keepFollowed: prefs.xprsKeepFollowed,
        keepChatter: prefs.xprsKeepChatter,
        quotaMb: prefs.xprsArchiveMaxMb,
        maxDays: prefs.xprsArchiveMaxDays,
        records: archive.countsByTier(),
        bytes: archive.spoolBytes,
        followedCallsigns: archive.followed.length,
        asksLastHour: XprsHistoryServer.instance.asksLastHour,
        answered: XprsHistoryServer.instance.answered,
        refused: XprsHistoryServer.instance.refused429,
        announced: claim,
        named: prefs.xprsNamedArchivers,
      );
      _files = _decode(NodeRoleApi.instance.archiveStatusJson());
      _dir = _decode(NodeRoleApi.instance.statusJson());
    });
  }

  Future<void> _apply(Map<String, dynamic> change) async {
    await applyArchiverSettings(change);
    _refresh();
  }

  void _filesPref(String kv) {
    NodeRoleApi.instance.archiveSetPref(kv);
    _refresh();
  }

  // ── small pieces ──────────────────────────────────────────────────────────

  static String _compact(Object? v) {
    final n = v is num ? v.toInt() : int.tryParse('$v') ?? 0;
    if (n >= 1000000000) return '${(n / 1e9).toStringAsFixed(1)}G';
    if (n >= 1000000) return '${(n / 1e6).toStringAsFixed(1)}M';
    if (n >= 10000) return '${(n / 1000).round()}k';
    return '$n';
  }

  Widget _section(BuildContext context, String title, List<Widget> children,
      {String? help}) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: tt.titleSmall?.copyWith(
                  color: cs.primary, fontWeight: FontWeight.w600)),
          if (help != null) ...[
            const SizedBox(height: 4),
            Text(help,
                style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          ],
          const SizedBox(height: 8),
          Card(
            elevation: 0,
            margin: EdgeInsets.zero,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: cs.outlineVariant.withAlpha(80)),
            ),
            color: cs.surfaceContainerLow,
            child: Column(children: children),
          ),
        ],
      ),
    );
  }

  Widget _tiles(BuildContext context, List<_Tile> tiles) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth >= 520 ? (c.maxWidth - 24) / 3 : (c.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final t in tiles)
              SizedBox(
                width: w,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(t.label,
                        style: tt.labelMedium
                            ?.copyWith(color: cs.onSurfaceVariant)),
                    const SizedBox(height: 2),
                    Text(t.value,
                        style: tt.titleLarge
                            ?.copyWith(fontWeight: FontWeight.w600)),
                    if (t.frac != null) ...[
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: t.frac),
                    ],
                    if (t.hint.isNotEmpty)
                      Text(t.hint,
                          style: tt.bodySmall
                              ?.copyWith(color: cs.onSurfaceVariant)),
                  ],
                ),
              ),
          ],
        );
      }),
    );
  }

  Widget _switch(String title, String? help, bool value,
      ValueChanged<bool>? onChanged, {IconData? icon}) {
    final cs = Theme.of(context).colorScheme;
    return SwitchListTile(
      secondary: icon == null ? null : Icon(icon),
      title: Text(title),
      subtitle: help == null
          ? null
          : Text(help, style: TextStyle(color: cs.onSurfaceVariant)),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _choice<T>(String title, T value, List<(T, String)> options,
      ValueChanged<T>? onChanged, {IconData? icon}) {
    return ListTile(
      leading: icon == null ? null : Icon(icon),
      title: Text(title),
      trailing: DropdownButton<T>(
        value: options.any((o) => o.$1 == value) ? value : options.first.$1,
        onChanged: onChanged == null ? null : (v) => v == null ? null : onChanged(v),
        items: [
          for (final o in options)
            DropdownMenuItem<T>(value: o.$1, child: Text(o.$2)),
        ],
      ),
    );
  }

  // ── tabs ──────────────────────────────────────────────────────────────────

  Widget _archiveTab(BuildContext context) {
    final a = _arch;
    final rec = a['records'] is Map ? a['records'] as Map : const {};
    final public = a['public'] == true;
    final announced = '${a['announced'] ?? ''}';
    final name = XprsArchive.instance.archiverName;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _section(context, tr('archiver.archive.title'), [
          ListTile(
            leading: const Icon(Icons.router_outlined),
            title: Text(name.isEmpty ? '—' : name,
                style: const TextStyle(
                    fontFamily: 'monospace', fontWeight: FontWeight.w600)),
            subtitle: Text(announced.isEmpty
                ? tr('archiver.archive.announces_nothing')
                : tr('archiver.archive.announces', {'claim': announced})),
          ),
          const Divider(height: 1),
          _tiles(context, [
            _Tile(tr('archiver.tile.mine'), _compact(rec['own']),
                tr('archiver.tile.mine.hint')),
            _Tile(tr('archiver.tile.followed'), _compact(rec['followed']),
                tr('archiver.tile.followed.hint',
                    {'n': '${a['followedCallsigns'] ?? 0}'})),
            _Tile(
                tr('archiver.tile.strangers'),
                public ? _compact(rec['stranger']) : '0',
                public
                    ? tr('archiver.tile.strangers.hint',
                        {'quota': '${a['quotaText'] ?? ''}'})
                    : tr('archiver.tile.strangers.off'),
                frac: public ? (a['fullFrac'] as num?)?.toDouble() : null),
            _Tile(tr('archiver.tile.disk'), '${a['bytesText'] ?? ''}',
                tr('archiver.tile.disk.hint', {'n': _compact(rec['total'])})),
            _Tile(tr('archiver.tile.asks'), '${a['asksLastHour'] ?? 0}',
                tr('archiver.tile.asks.hint', {
                  'answered': '${a['answered'] ?? 0}',
                  'refused': '${a['refused'] ?? 0}',
                })),
          ]),
        ], help: tr('archiver.archive.help')),
        _section(context, tr('archiver.keep.title'), [
          _switch(tr('archiver.keep.followed'), tr('archiver.keep.followed.help'),
              a['keepFollowed'] == true, (v) => _apply({'keepFollowed': v}),
              icon: Icons.people_outline),
          const Divider(height: 1),
          _switch(tr('archiver.keep.public'), tr('archiver.keep.public.help'),
              public, (v) => _apply({'public': v}),
              icon: Icons.public),
          const Divider(height: 1),
          _choice<int>(
              tr('archiver.keep.quota'),
              (a['quotaMb'] as num?)?.toInt() ?? 500,
              const [(100, '100 MB'), (500, '500 MB'), (2000, '2 GB'), (10000, '10 GB')],
              (v) => _apply({'quotaMb': v}),
              icon: Icons.storage),
          const Divider(height: 1),
          _choice<int>(
              tr('archiver.keep.days'),
              (a['maxDays'] as num?)?.toInt() ?? 365,
              [
                (7, tr('archiver.days', {'n': '7'})),
                (30, tr('archiver.days', {'n': '30'})),
                (90, tr('archiver.days', {'n': '90'})),
                (365, tr('archiver.days', {'n': '365'})),
              ],
              (v) => _apply({'maxDays': v}),
              icon: Icons.schedule),
        ]),
        _section(context, tr('archiver.serve.title'), [
          _switch(tr('archiver.serve.always_on'),
              tr(public ? 'archiver.serve.always_on.help' : 'archiver.serve.needs_public'),
              a['alwaysOn'] == true,
              public ? (v) => _apply({'alwaysOn': v}) : null,
              icon: Icons.bolt),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.lan_outlined),
            title: Text(tr('archiver.serve.dial')),
            subtitle: TextField(
              controller: _dial,
              enabled: public,
              decoration: InputDecoration(
                  hintText: tr('archiver.serve.dial.hint'), isDense: true),
              onSubmitted: (v) => _apply({'dial': v}),
            ),
          ),
          const Divider(height: 1),
          _switch(tr('archiver.serve.room'), tr('archiver.serve.room.help'),
              _prefs?.xprsRoom ?? true,
              public ? (v) => _apply({'room': v}) : null,
              icon: Icons.group_add_outlined),
        ], help: tr('archiver.serve.help')),
      ],
    );
  }

  Widget _filesTab(BuildContext context) {
    final f = _files;
    final quota = (f['quotaGb'] as num?)?.toInt() ?? 0;
    final on = quota != 0;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _section(context, tr('archiver.files.title'), [
          _tiles(context, [
            _Tile(tr('archiver.files.used'), '${f['usedText'] ?? ''}',
                on
                    ? tr('archiver.files.used.of', {'quota': '${f['quotaText'] ?? ''}'})
                    : tr('archiver.files.used.off'),
                frac: on ? (f['fullFrac'] as num?)?.toDouble() : null),
            _Tile(tr('archiver.files.requests'), '${f['reqAvgPerHour'] ?? 0}',
                tr('archiver.files.last_hour', {'n': '${f['reqLastHour'] ?? 0}'})),
            _Tile(tr('archiver.files.bandwidth'), '${f['bwPerHourText'] ?? ''}',
                tr('archiver.files.last_hour', {'n': '${f['bwLastHourText'] ?? ''}'})),
            _Tile(tr('archiver.files.kept'), _compact(f['items']), ''),
            _Tile(tr('archiver.files.served'), _compact(f['servedItems']), ''),
            _Tile(tr('archiver.files.freeable'), '${f['freeableText'] ?? ''}', ''),
          ]),
        ], help: tr('archiver.files.help')),
        _section(context, tr('archiver.files.settings'), [
          _switch(tr('archiver.files.enable'), null, on,
              (v) => _filesPref('quotaGb=${v ? (quota == 0 ? 5 : quota) : 0}'),
              icon: Icons.folder_shared_outlined),
          const Divider(height: 1),
          _choice<int>(tr('archiver.files.limit'), on ? quota : 5,
              const [(5, '5 GB'), (20, '20 GB'), (50, '50 GB'), (200, '200 GB')],
              on ? (v) => _filesPref('quotaGb=$v') : null,
              icon: Icons.storage),
          const Divider(height: 1),
          _switch(tr('archiver.files.followed'), null, f['followed'] == true,
              on ? (v) => _filesPref('followed=${v ? 1 : 0}') : null),
          const Divider(height: 1),
          _switch(tr('archiver.files.nearby'), null, f['fromNearby'] == true,
              on ? (v) => _filesPref('fromNearby=${v ? 1 : 0}') : null),
          const Divider(height: 1),
          _switch(tr('archiver.files.mirror'), null, f['mirrorSmall'] == true,
              on ? (v) => _filesPref('mirrorSmall=${v ? 1 : 0}') : null),
          const Divider(height: 1),
          ListTile(
            leading: Icon(Icons.delete_sweep_outlined,
                color: Theme.of(context).colorScheme.error),
            title: Text(tr('archiver.files.free')),
            subtitle: Text(tr('archiver.files.free.help',
                {'n': '${f['freeableText'] ?? ''}'})),
            onTap: _confirmFree,
          ),
        ]),
      ],
    );
  }

  Future<void> _confirmFree() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('archiver.files.free.confirm')),
        content: Text(tr('archiver.files.free.confirm.body')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('common.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('archiver.files.free'))),
        ],
      ),
    );
    if (ok != true) return;
    NodeRoleApi.instance.archiveSweep('sweep:all');
    _refresh();
  }

  Widget _directoryTab(BuildContext context) {
    final d = _dir;
    final volunteer = '${d['volunteer'] ?? 'off'}';
    final enabled = volunteer != 'off';
    final plugged = volunteer != 'always';
    void set(bool en, bool pl) {
      NodeRoleApi.instance
          .setPref('volunteer=${!en ? 'off' : (pl ? 'auto' : 'always')}');
      _refresh();
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _section(context, tr('archiver.dir.title'), [
          _tiles(context, [
            _Tile(tr('archiver.dir.queries'), '${d['queriesAvgPerHour'] ?? 0}',
                tr('archiver.files.last_hour', {'n': '${d['queriesLastHour'] ?? 0}'})),
            _Tile(tr('archiver.dir.links'), _compact(d['pointers']), ''),
            _Tile(tr('archiver.dir.authors'), _compact(d['authors']), ''),
            _Tile(tr('archiver.dir.synced'), _compact(d['syncPeers']), ''),
            _Tile(tr('archiver.dir.pruned'), _compact(d['demoted']), ''),
            _Tile(tr('archiver.dir.directories'), _compact(d['archiversKnown']), ''),
          ]),
        ], help: tr('archiver.dir.help')),
        _section(context, tr('archiver.files.settings'), [
          _switch(tr('archiver.dir.enable'), null, enabled,
              (v) => set(v, plugged), icon: Icons.hub_outlined),
          const Divider(height: 1),
          _switch(tr('archiver.dir.plugged'), null, plugged,
              enabled ? (v) => set(enabled, v) : null,
              icon: Icons.battery_charging_full),
        ]),
      ],
    );
  }

  Widget _mineTab(BuildContext context) {
    final prefs = _prefs;
    final list = prefs?.xprsArchivers ?? const <String>[];
    final self = XprsArchive.instance.archiverName;
    Future<void> setList(List<String> v) => _apply({'archivers': v});
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _section(context, tr('archiver.mine.title'), [
          _switch(tr('archiver.mine.auto'), tr('archiver.mine.auto.help'),
              prefs?.xprsArchiverAuto ?? true, (v) => _apply({'archiverAuto': v}),
              icon: Icons.auto_mode),
          for (final c in list) ...[
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.cloud_upload_outlined),
              title: Text(c, style: const TextStyle(fontFamily: 'monospace')),
              subtitle: Text(tr('archiver.mine.holds')),
              trailing: IconButton(
                tooltip: tr('archiver.mine.remove'),
                icon: const Icon(Icons.close),
                onPressed: () => setList([...list]..remove(c)),
              ),
            ),
          ],
        ], help: tr('archiver.mine.help')),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: TextField(
            controller: _search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: tr('archiver.mine.search'),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (q) => setState(() {
              _found = q.trim().length < 2
                  ? const []
                  : XprsNames.find(query: q.trim(), kind: 'station', limit: 20);
            }),
          ),
        ),
        for (final r in _found)
          if ('${r['call']}' != self && !list.contains('${r['call']}'))
            ListTile(
              leading: const Icon(Icons.add_circle_outline),
              title: Text('${r['call']}',
                  style: const TextStyle(fontFamily: 'monospace')),
              subtitle: Text('${r['nick'] ?? ''}'),
              onTap: () {
                setList([...list, '${r['call']}'.toUpperCase()]);
                _search.clear();
                setState(() => _found = const []);
              },
            ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('launcher.drawer.archiver')),
          bottom: TabBar(
            isScrollable: true,
            tabs: [
              Tab(icon: const Icon(Icons.inventory_2_outlined), text: tr('archiver.tab.archive')),
              Tab(icon: const Icon(Icons.folder_shared_outlined), text: tr('archiver.tab.files')),
              Tab(icon: const Icon(Icons.hub_outlined), text: tr('archiver.tab.directory')),
              Tab(icon: const Icon(Icons.cloud_upload_outlined), text: tr('archiver.tab.mine')),
            ],
          ),
        ),
        body: RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: TabBarView(children: [
            _archiveTab(context),
            _filesTab(context),
            _directoryTab(context),
            _mineTab(context),
          ]),
        ),
      ),
    );
  }
}

class _Tile {
  const _Tile(this.label, this.value, this.hint, {this.frac});
  final String label;
  final String value;
  final String hint;
  final double? frac;
}
