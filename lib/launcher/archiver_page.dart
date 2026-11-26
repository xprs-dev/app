// The Archiver: what this device keeps and serves for the network, and which
// archivers it relies on itself (XPRS.md section 12). A core function of the
// app, so a page of the app rather than a wapp; it replaced the Archive wapp.
//
// Three tabs:
//   Overview          the one switch, what the archiver gave (active for, data
//                     served, people served, requests), then the details
//   Our archiver      every setting of the archiver this device runs: messages,
//                     files, serving others, and its parts one by one. Not the
//                     `dial:` address (13.0.2): a server operator's setting,
//                     reached through the remote API, never a person's
//   Archivers we use  the archivers this station hands its words and mail to,
//                     each with what was last heard of it, and the others heard
//
// Every number comes from the core (xprsArchiveStatusJson, NodeRoleApi,
// XprsMonitor) and the daily log (ArchiverStats); every change goes through
// one writer (applyArchiverSettings) shared with the remote API, so the page
// and `/api/xprs/archiver` cannot drift apart.
//
// Reads are cheap counts and run when the page opens, after each change, on
// pull-to-refresh, and once a minute while the page is in front.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:xprs_core/src/services/social/node_role_api.dart';
import 'package:xprs_core/src/services/xprs/xprs_archivers_known.dart';
import 'package:xprs_core/src/services/xprs/xprs_conditions.dart';
import 'package:xprs_core/src/services/xprs/xprs_names.dart';
import 'package:xprs_core/src/services/xprs/xprs_vocab.dart' show xprsFmtDuration;
import 'package:xprs_core/src/profile/device_identity.dart';

import '../services/i18n/core_i18n.dart';
import '../services/i18n/format.dart';
import '../services/notification_service.dart';
import '../services/preferences_service.dart';
import '../services/reticulum/rns_service.dart';
import '../services/xprs/archiver_settings.dart';
import '../services/xprs/archiver_stats.dart';
import '../services/xprs/xprs_archive.dart';
import '../services/xprs/xprs_history_server.dart';
import '../services/xprs/xprs_monitor.dart';
import '../services/xprs/xprs_station_policy.dart';
import '../util/time_ago.dart';
import 'archiver_charts.dart';
import 'device_identity_card.dart';
import 'hardware_page.dart';

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
  final _search = TextEditingController();
  List<Map<String, Object>> _found = const [];
  List<ArchiverDay> _days = const [];
  List<XprsKnownArchiver> _known = const [];
  int _cared = 0;

  PreferencesService? get _prefs => PreferencesService.instanceSync;

  @override
  void initState() {
    super.initState();
    // Today's row is current when the page opens, not up to an hour old.
    ArchiverStats.instance.sample();
    _refresh();
    // Foreground-only, once a minute: the counts move slowly and nobody is
    // looking once the page is closed (docs/performance.md 6.5).
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _tick?.cancel();
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
      _days = ArchiverStats.instance.days;
      _cared = archive.caredFor();
      _known = xprsKnownArchivers();
    });
  }

  Future<void> _apply(Map<String, dynamic> change) async {
    await applyArchiverSettings(change);
    ArchiverStats.instance.sample();
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

  /// Bytes up to petabytes: an always-on archiver's lifetime outgrows GB.
  static String _bytes(num b) {
    final v = b.toInt();
    const tb = 1 << 40, pb = 1 << 50;
    if (v >= pb) return tr('archiver.unit.pb', {'n': trDecimal(v / pb, 1)});
    if (v >= tb) return tr('archiver.unit.tb', {'n': trDecimal(v / tb, 1)});
    return trBytes(v);
  }

  /// "4 months" since [ms].
  static String _age(int ms) {
    final days =
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms)).inDays;
    if (days < 1) return tr('archiver.age.today');
    if (days < 60) return tr('archiver.age.days', {'n': '$days'});
    if (days < 730) return tr('archiver.age.months', {'n': '${days ~/ 30}'});
    return tr('archiver.age.years', {'n': '${days ~/ 365}'});
  }

  static String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day}/${d.month}/${d.year}';
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

  static String _dayLabel(String d) {
    // yyyy-mm-dd -> d/m
    if (d.length != 10) return d;
    return '${int.parse(d.substring(8))}/${int.parse(d.substring(5, 7))}';
  }

  /// The last [n] calendar days, oldest first, a zero row for a day the app
  /// did not run (so the axis is time, not "days we have").
  List<ArchiverDay> _lastDays(int n) {
    final byDay = {for (final d in _days) d.d: d};
    final today = DateTime.now();
    return [
      for (var i = n - 1; i >= 0; i--)
        byDay[ArchiverStats.dayOf(today.subtract(Duration(days: i)))] ??
            ArchiverDay(ArchiverStats.dayOf(today.subtract(Duration(days: i)))),
    ];
  }

  Widget _plain(BuildContext context, String title, Widget child,
          {String? help}) =>
      _section(context, title, [
        // Full width even when the child is one short line of text.
        SizedBox(
          width: double.infinity,
          child: Padding(padding: const EdgeInsets.all(16), child: child),
        ),
      ], help: help);

  // ── overview ──────────────────────────────────────────────────────────────

  /// What is on, in a line: "Messages · Files · File index · Always on".
  String _status(PreferencesService p) => [
        if (p.xprsPublicArchiver) tr('archiver.status.messages'),
        if (p.archiveQuotaGb > 0) tr('archiver.status.files'),
        if (p.archiverVolunteer != 'off') tr('archiver.status.index'),
        if (p.xprsAlwaysOn) tr('archiver.status.always_on'),
        if (p.xprsPublicArchiver && !p.xprsRoom) tr('archiver.status.no_room'),
      ].join(' · ');

  /// THE switch, first on the page: the whole archiver on or off.
  Widget _switchCard(BuildContext context, PreferencesService p) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final on = archiverOn(p);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Material(
        color: on ? cs.primaryContainer : cs.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        clipBehavior: Clip.antiAlias,
        child: SwitchListTile(
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          secondary: Icon(on ? Icons.inventory_2 : Icons.inventory_2_outlined,
              size: 32, color: on ? cs.onPrimaryContainer : cs.onSurfaceVariant),
          title: Text(tr('archiver.switch'),
              style: tt.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: on ? cs.onPrimaryContainer : cs.onSurface)),
          subtitle: Text(on ? _status(p) : tr('archiver.switch.off'),
              style: TextStyle(
                  color: on ? cs.onPrimaryContainer : cs.onSurfaceVariant)),
          value: on,
          onChanged: (v) => _apply({'archiver': v}),
        ),
      ),
    );
  }

  Widget _overviewTab(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final p = _prefs;
    if (p == null) return const SizedBox.shrink();
    final a = _arch;
    final f = _files;
    final d = _dir;
    final rec = a['records'] is Map ? a['records'] as Map : const {};
    final d14 = _lastDays(14);
    final d30 = _lastDays(30);
    // The same count as the chart below: asks answered plus mail handed over.
    final answered30 = d30.fold<int>(0, (s, d) => s + d.ans + d.mail);
    final mail30 = d30.fold<int>(0, (s, d) => s + d.mail);
    final served14 = d14.fold<int>(0, (s, d) => s + d.srv);
    final since = p.xprsArchiverSinceMs;
    final storage = [
      for (final d in d30)
        if (d.bytes > 0) ChartPoint(_dayLabel(d.d), d.bytes.toDouble()),
    ];

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _switchCard(context, p),

        // ── summary ──
        _section(context, tr('archiver.overview.title'), [
          _tiles(context, [
            _Tile(
                tr('archiver.head.active'),
                since == 0 ? tr('archiver.head.active.never') : _age(since),
                since == 0
                    ? ''
                    : tr('archiver.head.active.since', {'date': _date(since)})),
            _Tile(tr('archiver.head.served'), _bytes(p.xprsServedBytesTotal),
                tr('archiver.head.served.hint')),
            _Tile(tr('archiver.head.people'), _compact(_cared),
                tr('archiver.head.people.hint')),
            _Tile(tr('archiver.head.answered'), _compact(answered30),
                tr('archiver.head.answered.hint')),
          ]),
        ]),
        _plain(
          context,
          tr('archiver.impact.chart.answers'),
          BarChart(
            points: [
              for (final d in d14)
                ChartPoint(_dayLabel(d.d), (d.ans + d.mail).toDouble()),
            ],
            idle: tr('archiver.impact.chart.answers.idle',
                {'n': '${d14.fold<int>(0, (s, d) => s + d.ans + d.mail)}'}),
            format: (p) => tr('archiver.impact.chart.answers.point',
                {'day': p.label, 'n': '${p.value.round()}'}),
          ),
          help: tr('archiver.impact.chart.answers.help'),
        ),

        // ── details ──
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 28, 16, 0),
          child: Text(tr('archiver.details'),
              style: tt.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        ),
        _plain(
          context,
          tr('archiver.chart.served'),
          BarChart(
            points: [
              for (final d in d14)
                ChartPoint(_dayLabel(d.d), d.srv.toDouble()),
            ],
            idle: tr('archiver.chart.served.idle', {'size': _bytes(served14)}),
            format: (p) => '${p.label}: ${_bytes(p.value)}',
          ),
        ),
        _section(context, tr('archiver.requests.title'), [
          _tiles(context, [
            _Tile(tr('archiver.tile.asks'), '${a['asksLastHour'] ?? 0}',
                tr('archiver.tile.asks.hint', {
                  'answered': '${a['answered'] ?? 0}',
                  'refused': '${a['refused'] ?? 0}',
                })),
            _Tile(tr('archiver.requests.mail'), _compact(mail30),
                tr('archiver.head.answered.hint')),
            _Tile(tr('archiver.requests.files'), '${f['reqAvgPerHour'] ?? 0}',
                tr('archiver.files.last_hour', {'n': '${f['reqLastHour'] ?? 0}'})),
            _Tile(tr('archiver.requests.bandwidth'), '${f['bwPerHourText'] ?? ''}',
                tr('archiver.files.last_hour', {'n': '${f['bwLastHourText'] ?? ''}'})),
          ]),
        ]),
        _plain(
          context,
          tr('archiver.impact.chart.storage'),
          storage.length < 2
              ? Text(tr('archiver.impact.collecting'),
                  style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant))
              : LineChart(
                  points: storage,
                  idle: tr('archiver.impact.chart.storage.idle',
                      {'size': _bytes(storage.last.value)}),
                  format: (p) => '${p.label}: ${_bytes(p.value)}',
                ),
        ),
        _plain(
          context,
          tr('archiver.impact.split'),
          SplitBar(parts: [
            (tr('archiver.tile.mine'), ((rec['own'] as num?) ?? 0).toDouble(),
                _compact(rec['own'])),
            (tr('archiver.tile.followed'),
                ((rec['followed'] as num?) ?? 0).toDouble(),
                _compact(rec['followed'])),
            (tr('archiver.tile.strangers'),
                ((rec['stranger'] as num?) ?? 0).toDouble(),
                _compact(rec['stranger'])),
          ]),
          help: tr('archiver.impact.split.help'),
        ),
        _section(context, tr('archiver.held.title'), [
          _tiles(context, [
            _Tile(tr('archiver.tile.disk'), '${a['bytesText'] ?? ''}',
                tr('archiver.tile.disk.hint', {'n': _compact(rec['total'])})),
            _Tile(tr('archiver.files.used'), '${f['usedText'] ?? ''}',
                tr('archiver.held.files', {'n': _compact(f['items'])})),
            _Tile(tr('archiver.files.served'), _compact(f['servedItems']), ''),
          ]),
        ]),
        _section(context, tr('archiver.index.title'), [
          _tiles(context, [
            _Tile(tr('archiver.dir.links'), _compact(d['pointers']), ''),
            _Tile(tr('archiver.dir.synced'), _compact(d['syncPeers']), ''),
            _Tile(tr('archiver.dir.queries'), '${d['queriesAvgPerHour'] ?? 0}',
                tr('archiver.files.last_hour', {'n': '${d['queriesLastHour'] ?? 0}'})),
          ]),
        ], help: tr('archiver.index.help')),
      ],
    );
  }

  // ── our archiver ──────────────────────────────────────────────────────────

  /// One limit for the file store, admitted and kept alike.
  static const List<int> _fileLimits = [1, 5, 10, 25, 50, 100, 200];

  Widget _settingsTab(BuildContext context) {
    final p = _prefs;
    if (p == null) return const SizedBox.shrink();
    final a = _arch;
    final f = _files;
    final public = p.xprsPublicArchiver;
    final files = p.archiveQuotaGb > 0;
    final index = p.archiverVolunteer != 'off';
    final announced = '${a['announced'] ?? ''}';
    final name = XprsArchive.instance.archiverName;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _section(context, tr('archiver.archive.title'), [
          ListTile(
            leading: const Icon(Icons.router_outlined),
            title: Text(name.isEmpty ? '-' : name,
                style: const TextStyle(
                    fontFamily: 'monospace', fontWeight: FontWeight.w600)),
            subtitle: Text(announced.isEmpty
                ? tr('archiver.archive.announces_nothing')
                : tr('archiver.archive.announces', {'claim': announced})),
            // The archiver's name is the device's X3: pick another here, as
            // in Settings > This device.
            trailing: DeviceIdentity.instance.ready &&
                    !DeviceIdentity.instance.isProfileKey
                ? IconButton(
                    tooltip: tr('settings.device.change'),
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () async {
                      if (await changeStationCallsign(context)) _refresh();
                    },
                  )
                : null,
          ),
        ], help: tr('archiver.archive.help')),
        _section(context, tr('archiver.set.messages'), [
          _switch(tr('archiver.keep.followed'), tr('archiver.keep.followed.help'),
              a['keepFollowed'] == true, (v) => _apply({'keepFollowed': v}),
              icon: Icons.people_outline),
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
        _section(context, tr('archiver.set.files'), [
          _choice<int>(tr('archiver.files.limit'), p.hostCeilingGb,
              [for (final g in _fileLimits) (g, '$g GB')],
              (v) => _apply({'filesGb': v}),
              icon: Icons.sd_storage_outlined),
          const Divider(height: 1),
          _switch(tr('archiver.files.followed'), null, f['followed'] == true,
              files ? (v) => _filesPref('followed=${v ? 1 : 0}') : null),
          const Divider(height: 1),
          _switch(tr('archiver.files.nearby'), null, f['fromNearby'] == true,
              files ? (v) => _filesPref('fromNearby=${v ? 1 : 0}') : null),
          const Divider(height: 1),
          _switch(tr('archiver.files.mirror'), null, f['mirrorSmall'] == true,
              files ? (v) => _filesPref('mirrorSmall=${v ? 1 : 0}') : null),
          const Divider(height: 1),
          ListTile(
            leading: Icon(Icons.delete_sweep_outlined,
                color: Theme.of(context).colorScheme.error),
            title: Text(tr('archiver.files.free')),
            subtitle: Text(tr('archiver.files.free.help',
                {'n': '${f['freeableText'] ?? ''}'})),
            onTap: _confirmFree,
          ),
        ], help: tr('archiver.files.help')),
        _section(context, tr('archiver.serve.title'), [
          _switch(tr('archiver.set.charging'), tr('archiver.set.charging.help'),
              p.hostCapacityGated, (v) => _apply({'onlyCharging': v}),
              icon: Icons.battery_charging_full),
          const Divider(height: 1),
          _switch(tr('archiver.serve.always_on'),
              tr(public ? 'archiver.serve.always_on.help' : 'archiver.serve.needs_public'),
              a['alwaysOn'] == true,
              public ? (v) => _apply({'alwaysOn': v}) : null,
              icon: Icons.bolt),
          const Divider(height: 1),
          _switch(tr('archiver.serve.room'), tr('archiver.serve.room.help'),
              p.xprsRoom, public ? (v) => _apply({'room': v}) : null,
              icon: Icons.group_add_outlined),
        ]),
        _section(context, tr('archiver.set.hardware'), [
          ListTile(
            leading: const Icon(Icons.electrical_services),
            title: Text(tr('archiver.set.hardware.open')),
            subtitle: Text(tr('archiver.set.hardware.help')),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(
                  builder: (_) => const HardwarePage()));
              _refresh();
            },
          ),
        ]),
        _section(context, tr('archiver.set.advanced'), [
          _switch(tr('archiver.part.messages'), tr('archiver.part.messages.help'),
              public, (v) => _apply({'public': v}),
              icon: Icons.public),
          const Divider(height: 1),
          _switch(tr('archiver.part.files'), tr('archiver.part.files.help'),
              files, (v) => _apply({'files': v}),
              icon: Icons.folder_shared_outlined),
          const Divider(height: 1),
          _switch(tr('archiver.part.index'), tr('archiver.part.index.help'),
              index, (v) => _apply({'fileIndex': v}),
              icon: Icons.hub_outlined),
        ], help: tr('archiver.set.advanced.help')),
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

  // ── archivers we use ──────────────────────────────────────────────────────

  static String _how(String bearer) => switch (bearer) {
        'rns' => tr('archiver.how.internet'),
        'lan' => tr('archiver.how.lan'),
        'ble5' || 'ble' => tr('archiver.how.bluetooth'),
        'lora' || 'espnow' => tr('archiver.how.radio'),
        _ => bearer,
      };

  /// What is known of one archiver, as up to three lines: when it was last
  /// heard (or announced, when only the cache knows it), what it offers, and
  /// what keeps it going (13.0.5). The cache [k] is the archiver's own
  /// announcement; [st] and [rns] are what this device heard itself.
  List<String> _facts(String call, XprsStation? st,
      ({String callsign, int lastSeenMs, int uptimeS})? rns,
      XprsKnownArchiver? k) {
    final heardMs = [st?.lastMs ?? 0, rns?.lastSeenMs ?? 0]
        .reduce((x, y) => x > y ? x : y);
    final String when;
    if (heardMs > 0) {
      when = tr('archiver.used.heard', {
        'ago': timeAgo(DateTime.fromMillisecondsSinceEpoch(heardMs)),
        'how': _how(st != null && st.lastMs >= (rns?.lastSeenMs ?? 0)
            ? st.bearer
            : 'rns'),
      });
    } else if (k != null && k.announcedMs > 0) {
      when = tr(k.stale ? 'archiver.used.stale' : 'archiver.used.announced', {
        'ago': timeAgo(DateTime.fromMillisecondsSinceEpoch(k.announcedMs)),
      });
    } else {
      when = tr('archiver.used.not_heard');
    }
    final count = k?.count ?? st?.count;
    final offer = [
      if (k?.sizeBytes != null)
        tr('archiver.used.free', {'size': xprsStepBytes(k!.sizeBytes!)}),
      if (count != null) tr('archiver.used.records', {'n': _compact(count)}),
      if (k?.room == false || st?.room == 'no') tr('archiver.status.no_room'),
    ].join(' · ');
    final source = k?.source ?? st?.readings['source'];
    final backup = k?.backup ?? st?.readings['backup'];
    final uplink = k?.uplink ?? st?.readings['uplink'];
    final uptime = k?.uptime ??
        st?.uptime ??
        ((rns?.uptimeS ?? 0) > 0 ? xprsFmtDuration(rns!.uptimeS) : null);
    final keeps = [
      if (source != null)
        tr(source != 'grid'
            ? 'hardware.summary.outage.runs'
            : (backup != null && backup != 'none')
                ? 'hardware.summary.outage.backup'
                : 'hardware.summary.outage.stops'),
      if (uplink != null &&
          const {'wifi', 'lan', 'cellular', 'satellite', 'none'}.contains(uplink))
        tr('hardware.internet.$uplink'),
      if (k?.bwBytesPerS != null) xprsStepRate(k!.bwBytesPerS!)!,
      if (uptime != null) tr('archiver.used.uptime', {'t': uptime}),
    ].join(' · ');
    return [when, if (offer.isNotEmpty) offer, if (keeps.isNotEmpty) keeps];
  }

  Widget _archiverTile(String call, XprsStation? st,
      ({String callsign, int lastSeenMs, int uptimeS})? rns,
      XprsKnownArchiver? k,
      {required Widget trailing, required bool chosen}) {
    final cs = Theme.of(context).colorScheme;
    final facts = _facts(call, st, rns, k);
    return ListTile(
      leading: Icon(chosen ? Icons.cloud_done_outlined : Icons.cloud_outlined,
          color: chosen ? cs.primary : cs.onSurfaceVariant),
      title: Text(call,
          style: const TextStyle(
              fontFamily: 'monospace', fontWeight: FontWeight.w600)),
      subtitle: Text(facts.join('\n'),
          style: TextStyle(color: cs.onSurfaceVariant)),
      isThreeLine: facts.length > 1,
      trailing: trailing,
    );
  }

  Widget _usedTab(BuildContext context) {
    final prefs = _prefs;
    final list = prefs?.xprsArchivers ?? const <String>[];
    final self = XprsArchive.instance.archiverName.toUpperCase();
    final heard = XprsMonitor.instance.stations;
    final announced = {
      // arch-ignore: no-core-calls-from-screen a read of who announced, for display; nothing is chosen, sent or fetched
      for (final a in RnsService.instance.announcedArchivers())
        a.callsign.toUpperCase(): a,
    };
    XprsStation? st(String c) => heard[c] ?? heard[c.toUpperCase()];
    Future<void> setList(List<String> v) => _apply({'archivers': v});
    final known = {for (final k in _known) k.callsign: k};

    // Every other archiver this device knows of: from the cache of their
    // announcements (13.0.5) in the order a station chooses in, then any
    // heard announcing serve:archive or on Reticulum that the cache does
    // not hold yet, most records first.
    final excluded = {self, ...list};
    final ranked = [
      for (final k in _known)
        if (!excluded.contains(k.callsign)) k.callsign,
    ];
    final extra = <String>{
      for (final s in heard.values)
        if (s.services.contains('archive')) s.callsign.toUpperCase(),
      ...announced.keys,
    }..removeWhere((c) => excluded.contains(c) || known.containsKey(c));
    ranked.addAll(extra.toList()
      ..sort((x, y) => (st(y)?.count ?? 0).compareTo(st(x)?.count ?? 0)));

    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _section(context, tr('archiver.mine.title'), [
          _switch(tr('archiver.mine.auto'), tr('archiver.mine.auto.help'),
              prefs?.xprsArchiverAuto ?? true, (v) => _apply({'archiverAuto': v}),
              icon: Icons.auto_mode),
          for (final c in list) ...[
            const Divider(height: 1),
            _archiverTile(c, st(c), announced[c.toUpperCase()],
                known[c.toUpperCase()],
                chosen: true,
                trailing: IconButton(
                  tooltip: tr('archiver.mine.remove'),
                  icon: const Icon(Icons.close),
                  onPressed: () => setList([...list]..remove(c)),
                )),
          ],
        ], help: tr('archiver.mine.help')),
        _section(context, tr('archiver.used.others'), [
          if (ranked.isEmpty)
            ListTile(title: Text(tr('archiver.used.others.none'))),
          for (var i = 0; i < ranked.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _archiverTile(ranked[i], st(ranked[i]), announced[ranked[i]],
                known[ranked[i]],
                chosen: false,
                trailing: TextButton(
                  onPressed: () => setList([...list, ranked[i]]),
                  child: Text(tr('archiver.used.add')),
                )),
          ],
        ]),
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
          if ('${r['call']}'.toUpperCase() != self &&
              !list.contains('${r['call']}'.toUpperCase()))
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
  Widget build(BuildContext context) => NotificationTargetView(
      source: ArchiverPage.target, child: _page(context));

  Widget _page(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('launcher.drawer.archiver')),
          bottom: TabBar(
            tabs: [
              Tab(icon: const Icon(Icons.insights_outlined), text: tr('archiver.tab.overview')),
              Tab(icon: const Icon(Icons.tune), text: tr('archiver.tab.settings')),
              Tab(icon: const Icon(Icons.cloud_upload_outlined), text: tr('archiver.tab.used')),
            ],
          ),
        ),
        body: RefreshIndicator(
          onRefresh: () async => _refresh(),
          child: TabBarView(children: [
            _overviewTab(context),
            _settingsTab(context),
            _usedTab(context),
          ]),
        ),
      ),
    );
  }
}

class _Tile {
  const _Tile(this.label, this.value, this.hint);
  final String label;
  final String value;
  final String hint;
}
