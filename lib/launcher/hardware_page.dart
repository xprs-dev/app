import 'dart:async';

import 'package:flutter/material.dart';

import '../services/preferences_service.dart';
import '../services/social/node_profile_service.dart';
import '../services/i18n/core_i18n.dart';
import '../services/power_state.dart';
import '../platform/platform.dart' as platform;
import 'package:xprs_core/src/services/files/capacity_governor.dart';
import 'package:xprs_core/src/services/xprs/xprs_conditions.dart';

/// Settings > Hardware: what keeps this device going, as XPRS announces it
/// (XPRS.md 13.0.4: `source:`, `backup:`, `uplink:`, `plan:`).
///
/// Stated once, for the device, and read by every role. The summary at the
/// top is built from the choices below and changes with them; the measured
/// numbers (time powered, observed speed) sit next to the stated ones.
class HardwarePage extends StatefulWidget {
  const HardwarePage({super.key});

  @override
  State<HardwarePage> createState() => _HardwarePageState();
}

class _HardwarePageState extends State<HardwarePage> {
  static const _auto = 'auto';
  PreferencesService? _prefs;

  /// "Battery" or "Plugged to energy": seen, never stated. A desktop with no
  /// battery counts as plugged in (PowerState.isPowered).
  final _powered = PowerState.instance.powered;

  /// The network the device is on, followed live: the link type and the
  /// data plan change with it unless the owner picked them.
  final _net = CapacityGovernor.instance.netKind;

  @override
  void initState() {
    super.initState();
    _prefs = PreferencesService.instanceSync;
    _powered.addListener(_onPower);
    _net.addListener(_onPower);
    // Fresh on open rather than up to a minute old.
    unawaited(CapacityGovernor.instance.evaluate());
  }

  @override
  void dispose() {
    _powered.removeListener(_onPower);
    _net.removeListener(_onPower);
    super.dispose();
  }

  void _onPower() {
    if (mounted) setState(() {});
  }

  NodeProfileService get _svc => NodeProfileService.instance;

  void _save(VoidCallback change) {
    setState(change);
  }

  String get _seenUplink => xprsSeenUplink(_net.value.name);

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = _prefs;
    if (p == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final profile = _svc.build();
    final source = p.nodeSource ?? 'grid';
    final backup = p.nodeBackup ?? xprsDefaultBackup(platform.platformName());
    final seen = _seenUplink;
    final uplink = p.nodeUplinkWord ?? seen;
    final statedPlan = p.nodePlanFor(uplink);
    final plan = statedPlan ?? xprsDefaultPlan(uplink);

    return Scaffold(
      appBar: AppBar(title: Text(tr('hardware.title'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          _header(context, tr('hardware.device_type')),
          _card(
            cs,
            _summary(cs,
                source: source, backup: backup, uplink: uplink, plan: plan),
          ),
          const SizedBox(height: 20),

          _header(context, tr('hardware.power')),
          _card(
            cs,
            Column(children: [
              ListTile(
                leading: Icon(_powered.value
                    ? Icons.power
                    : Icons.battery_std),
                title: Text(tr('hardware.power.source')),
                subtitle: Text(_powered.value
                    ? tr('hardware.power.plugged')
                    : tr('hardware.power.battery')),
              ),
              // A dropdown belongs in the BODY of the row, not in a ListTile's
              // trailing slot: given a wide child, the tile crushes its title to
              // one letter per line. Full-width field, label above.
              _choice(cs,
                  icon: Icons.bolt,
                  label: tr('hardware.energy'),
                  value: source,
                  words: kXprsSourceChoices,
                  prefix: 'hardware.energy.',
                  onChanged: (v) => _save(() => p.nodeSource = v)),
              _choice(cs,
                  icon: Icons.battery_charging_full,
                  label: tr('hardware.backup'),
                  value: backup,
                  words: kXprsBackupChoices,
                  prefix: 'hardware.backup.',
                  onChanged: (v) => _save(() => p.nodeBackup = v)),
              // Only once it has been watched: "Powered 0%" above "not
              // watched long enough to say" contradicted itself.
              if (profile.poweredPct > 0)
                _measured(
                  cs,
                  tr('hardware.powered.pct', {'pct': profile.poweredPct}),
                  tr('hardware.powered.measured'),
                ),
              const SizedBox(height: 8),
            ]),
          ),
          const SizedBox(height: 20),

          _header(context, tr('hardware.internet')),
          _card(
            cs,
            Column(children: [
              // "Automatic" follows the network; any other word pins it (a
              // satellite dish looks like Wi-Fi from in here).
              _field(
                cs,
                icon: Icons.public,
                label: tr('hardware.internet.link'),
                child: DropdownButton<String>(
                  value: p.nodeUplinkWord ?? _auto,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem(
                        value: _auto,
                        child: Text(tr('hardware.auto.value', {
                          'value': tr('hardware.internet.$seen'),
                        }))),
                    for (final w in kXprsUplinkChoices)
                      DropdownMenuItem(
                          value: w, child: Text(tr('hardware.internet.$w'))),
                  ],
                  onChanged: (v) => _save(
                      () => p.nodeUplinkWord = v == _auto ? null : v),
                ),
              ),
              // One plan per kind of link: on Wi-Fi it says Wi-Fi's, on the
              // mobile network the phone's own, each defaulted until changed.
              if (uplink != 'none')
                _choice(cs,
                    icon: Icons.data_usage,
                    label: tr('hardware.plan'),
                    hint: statedPlan == null ? tr('hardware.auto') : null,
                    value: plan,
                    words: kXprsPlanChoices,
                    prefix: 'hardware.plan.',
                    onChanged: (v) => _save(() {
                          p.setNodePlanFor(
                              uplink, v == xprsDefaultPlan(uplink) ? null : v);
                          // The one switch for serving files over mobile
                          // data: an unlimited mobile plan can afford it.
                          if (uplink == 'cellular') {
                            p.fileServeOnCellular = v == 'unlimited';
                          }
                        })),
              // Shown once there is a measurement: until something has been
              // timed, "not measured yet" was all this line could ever say.
              if (profile.bwClass > 0)
                _measured(
                  cs,
                  tr('hardware.speed.observed', {'bw': _bw(profile.bwClass)}),
                  tr('hardware.speed.why'),
                ),
              const SizedBox(height: 8),
            ]),
          ),
        ],
      ),
    );
  }

  /// One 13.0.4 key as a dropdown of its words, labelled `<prefix><word>`.
  Widget _choice(
    ColorScheme cs, {
    required IconData icon,
    required String label,
    required String value,
    required List<String> words,
    required String prefix,
    required ValueChanged<String> onChanged,
    String? hint,
  }) =>
      _field(
        cs,
        icon: icon,
        label: label,
        value: hint,
        child: DropdownButton<String>(
          value: words.contains(value) ? value : null,
          isExpanded: true,
          underline: const SizedBox.shrink(),
          items: [
            for (final w in words)
              DropdownMenuItem(value: w, child: Text(tr('$prefix$w'))),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      );

  /// The choices below, read back as four lines: what the device is, its
  /// energy, its internet, and what a power cut does to it.
  Widget _summary(ColorScheme cs,
      {required String source,
      required String backup,
      required String uplink,
      required String plan}) {
    final phone = const {'android', 'ios'}.contains(platform.platformName());
    final energy = backup == 'none'
        ? '${tr('hardware.energy.$source')} · ${tr('hardware.summary.no_backup')}'
        : '${tr('hardware.energy.$source')} · '
            '${tr('hardware.summary.backup', {'backup': tr('hardware.backup.$backup')})}';
    final internet = uplink == 'none'
        ? tr('hardware.internet.none')
        : '${tr('hardware.internet.$uplink')} · ${tr('hardware.plan.$plan')}';
    final outage = source != 'grid'
        ? tr('hardware.summary.outage.runs')
        : backup != 'none'
            ? tr('hardware.summary.outage.backup')
            : tr('hardware.summary.outage.stops');
    final rows = [
      (tr('hardware.summary.device'),
          tr(phone ? 'hardware.kind.phone' : 'hardware.kind.computer')),
      (tr('hardware.summary.energy'), energy),
      (tr('hardware.internet'), internet),
      (tr('hardware.summary.outage'), outage),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 120,
                  child: Text(label,
                      style: TextStyle(color: cs.onSurfaceVariant)),
                ),
                Expanded(
                  child: Text(value,
                      style: TextStyle(
                          color: cs.onSurface, fontWeight: FontWeight.w500)),
                ),
              ],
            ),
          ),
      ]),
    );
  }

  Widget _header(BuildContext context, String s) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(s,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                )),
      );

  /// A full-width labelled control. Deliberately NOT a ListTile with a wide
  /// `trailing`: that layout crushes the title into one letter per line the
  /// moment the control needs room.
  Widget _field(
    ColorScheme cs, {
    required IconData icon,
    required String label,
    String? value,
    required Widget child,
  }) =>
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Icon(icon, color: cs.onSurfaceVariant),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          color: cs.onSurface, fontWeight: FontWeight.w500)),
                  if (value != null)
                    Text(value,
                        style: TextStyle(
                            color: cs.onSurfaceVariant, fontSize: 12)),
                  child,
                ],
              ),
            ),
          ],
        ),
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

  Widget _measured(ColorScheme cs, String title, String why) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.insights, size: 18, color: cs.onSurfaceVariant),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: cs.onSurface, fontWeight: FontWeight.w500)),
                  Text(why,
                      style: TextStyle(
                          color: cs.onSurfaceVariant, fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      );

  static String _bw(int cls) {
    final bps = 1 << cls;
    if (bps > 1000000) return '${(bps / 1000000).toStringAsFixed(1)} MB/s';
    if (bps > 1000) return '${(bps / 1000).toStringAsFixed(0)} kB/s';
    return '$bps B/s';
  }
}
