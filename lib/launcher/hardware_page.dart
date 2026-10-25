import 'dart:async';

import 'package:flutter/material.dart';
import 'package:reticulum/src/services/social/listening_schedule.dart';
import 'package:reticulum/src/services/social/node_profile.dart';

import '../services/i18n/schedule_text.dart';

import '../services/location_service.dart';
import '../services/preferences_service.dart';
import '../services/social/node_profile_service.dart';
import '../util/geohash.dart';
import '../services/i18n/core_i18n.dart';

/// Settings → Hardware: what this device is made of (docs/NOSTR.md).
///
/// Stated ONCE, for the device, and read by every role — a box volunteered as
/// both an Indexer and an Archiver must not be asked twice what it is plugged
/// into, and two answers that can disagree is a bug waiting to be filed.
///
/// Full-size on purpose: the value is in the *combinations* — power source ×
/// uplink × which radios are actually attached — and a settings row cannot lay
/// that out.
///
/// Nothing here is a boast. The device announces facts; every other node scores
/// them for itself, and what it has *observed* about us always beats what we
/// *claimed*. So the page shows the measured numbers next to the stated ones,
/// where the two can be compared honestly.
class HardwarePage extends StatefulWidget {
  const HardwarePage({super.key});

  @override
  State<HardwarePage> createState() => _HardwarePageState();
}

class _HardwarePageState extends State<HardwarePage> {
  PreferencesService? _prefs;

  @override
  void initState() {
    super.initState();
    _prefs = PreferencesService.instanceSync;
  }

  NodeProfileService get _svc => NodeProfileService.instance;

  void _save(VoidCallback change) {
    setState(change);
  }

  /// The device's own position, or null when there is no fix.
  ///
  /// Coverage has to be derived from where the device actually is. It used to
  /// store the literal string 'u0' whenever the switch was turned on, so every
  /// node that enabled Coverage advertised the same region in the Baltic
  /// regardless of where it stood, and the network was told a location nobody
  /// had measured.
  Future<({double lat, double lon})?> _position() async {
    final loc = LocationService.instance;
    loc.ensureStarted();
    final lat = loc.latE7, lon = loc.lonE7;
    if (lat != null && lon != null) {
      return (lat: lat / 1e7, lon: lon / 1e7);
    }
    return loc.currentPosition();
  }

  /// Re-encode the coverage region at [precision] from the current fix.
  ///
  /// Always re-encoded, never padded: dropping characters coarsens a geohash,
  /// but appending them names a different place. Refining therefore has to go
  /// back to the coordinates.
  Future<void> _setCoverage(int precision) async {
    final p = _prefs;
    if (p == null) return;
    final at = await _position();
    if (!mounted) return;
    if (at == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(tr('hardware.no_fix')),
      ));
      _save(() => p.nodeGeohash = '');
      return;
    }
    _save(() => p.nodeGeohash =
        geohashEncode(at.lat, at.lon, precision: precision));
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final p = _prefs;
    if (p == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final profile = _svc.build();

    return Scaffold(
      appBar: AppBar(title: Text(tr('hardware.title'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            tr('hardware.intro'),
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
          const SizedBox(height: 20),

          _header(context, tr('hardware.power')),
          _card(
            cs,
            Column(children: [
              // A dropdown belongs in the BODY of the row, not in a ListTile's
              // trailing slot: given a wide child, the tile crushes its title to
              // one letter per line. Full-width field, label above.
              _field(
                cs,
                icon: Icons.bolt,
                label: tr('hardware.power.source'),
                child: DropdownButton<int>(
                  value: p.nodePower,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem(value: -1, child: Text(tr('hardware.power.not_stated'))),
                    for (var i = 0; i < PowerSource.values.length - 1; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(_powerLabel(PowerSource.values[i])),
                      ),
                  ],
                  onChanged: (v) => _save(() => p.nodePower = v ?? -1),
                ),
              ),
              _field(
                cs,
                icon: Icons.battery_charging_full,
                label: tr('hardware.autonomy'),
                value: p.nodeAutonomyHours == 0
                    ? tr('common.unknown')
                    : tr('hardware.autonomy.hours', {'n': p.nodeAutonomyHours}),
                child: Slider(
                  value: p.nodeAutonomyHours.clamp(0, 168).toDouble(),
                  max: 168,
                  divisions: 24,
                  onChanged: (v) => _save(() => p.nodeAutonomyHours = v.round()),
                ),
              ),
              _measured(
                cs,
                tr('hardware.powered.pct', {'pct': profile.poweredPct}),
                profile.poweredPct == 0
                    ? tr('hardware.powered.unwatched')
                    : tr('hardware.powered.measured'),
              ),
            ]),
          ),
          const SizedBox(height: 20),

          _header(context, tr('hardware.uplink')),
          _card(
            cs,
            Column(children: [
              _field(
                cs,
                icon: Icons.public,
                label: tr('hardware.uplink.label'),
                value: tr('hardware.uplink.now', {'uplink': _uplinkLabel(profile.uplink)}),
                child: DropdownButton<int>(
                  value: p.nodeUplink,
                  isExpanded: true,
                  underline: const SizedBox.shrink(),
                  items: [
                    DropdownMenuItem(
                        value: -1, child: Text(tr('hardware.uplink.detect'))),
                    for (var i = 0; i < UplinkKind.values.length - 1; i++)
                      DropdownMenuItem(
                        value: i,
                        child: Text(_uplinkLabel(UplinkKind.values[i])),
                      ),
                  ],
                  onChanged: (v) => _save(() => p.nodeUplink = v ?? -1),
                ),
              ),
              _measured(
                cs,
                profile.bwClass == 0
                    ? tr('hardware.speed.unmeasured')
                    : tr('hardware.speed.observed', {'bw': _bw(profile.bwClass)}),
                tr('hardware.speed.why'),
              ),
            ]),
          ),
          const SizedBox(height: 20),

          _header(context, tr('hardware.coverage')),
          _card(
            cs,
            Column(children: [
              SwitchListTile(
                secondary: const Icon(Icons.place_outlined),
                title: Text(tr('hardware.coverage.title')),
                subtitle: Text(p.nodeGeohash.isEmpty
                    ? tr('hardware.coverage.off')
                    : tr('hardware.coverage.region', {
                        'geohash': p.nodeGeohash,
                        'precision': _precisionKm(p.nodeGeohash)
                      })),
                value: p.nodeGeohash.isNotEmpty,
                onChanged: (on) {
                  if (!on) {
                    _save(() => p.nodeGeohash = '');
                    return;
                  }
                  unawaited(_setCoverage(4));
                },
              ),
              if (p.nodeGeohash.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('hardware.coverage.precision'),
                        style: TextStyle(
                            color: cs.onSurfaceVariant, fontSize: 12),
                      ),
                      Slider(
                        value: p.nodeGeohash.length.clamp(2, 6).toDouble(),
                        min: 2,
                        max: 6,
                        divisions: 4,
                        label: _precisionKm(p.nodeGeohash),
                        onChanged: (v) => unawaited(_setCoverage(v.round())),
                      ),
                      Text(
                        tr('hardware.coverage.phone'),
                        style: TextStyle(
                            color: cs.onSurfaceVariant, fontSize: 12),
                      ),
                    ],
                  ),
                ),
            ]),
          ),
          const SizedBox(height: 20),

          _header(context, tr('hardware.radios')),
          Text(
            tr('hardware.radios.intro'),
            style: TextStyle(color: cs.onSurfaceVariant, fontSize: 12),
          ),
          const SizedBox(height: 8),
          _card(
            cs,
            Column(children: [
              for (final r in _svc.radios)
                ListTile(
                  leading: Icon(_linkIcon(r.link)),
                  title: Text('${_linkLabel(r.link)} · ${r.rangeKm} km'),
                  subtitle: Text([
                    if (r.freqKhz > 0) _freq(r.freqKhz),
                    if (r.mode.isNotEmpty) r.mode,
                    trSchedule(r.schedule),
                  ].join(' · ')),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _save(() {
                      final rs = _svc.radios..removeWhere((x) => x.link == r.link);
                      _svc.radios = rs;
                    }),
                  ),
                ),
              ListTile(
                leading: const Icon(Icons.add),
                title: Text(tr('hardware.radio.add')),
                onTap: _addRadio,
              ),
            ]),
          ),
          const SizedBox(height: 24),

          _card(
            cs,
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('hardware.meaning'),
                      style: TextStyle(
                          color: cs.primary, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Text(_verdict(profile),
                      style: TextStyle(color: cs.onSurface)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The honest, two-mode reading of the profile. People who own hardware that
  /// matters in a disaster should be told — they are the ones who decide
  /// whether to keep it running.
  String _verdict(NodeProfile p) {
    final normal = p.uplink == UplinkKind.fibre || p.uplink == UplinkKind.wifi
        ? tr('hardware.verdict.normal.fast')
        : p.uplink == UplinkKind.cellular
            ? tr('hardware.verdict.normal.phone')
            : tr('hardware.verdict.normal.plain');

    final String outage;
    if (p.gridIndependent && p.uplinkIndependent && p.reachableOffgrid) {
      outage = tr('hardware.verdict.best');
    } else if (p.gridIndependent && p.reachableOffgrid) {
      outage = tr('hardware.verdict.offgrid');
    } else if (p.gridIndependent) {
      outage = tr('hardware.verdict.power');
    } else if (p.reachableOffgrid) {
      outage = tr('hardware.verdict.reach');
    } else {
      outage = tr('hardware.verdict.depends');
    }
    return '$normal\n\n$outage';
  }

  Future<void> _addRadio() async {
    var link = LinkFlag.lora;
    var range = 5;
    var freq = 868200;
    var mode = 'LoRa-SF7BW125';
    var schedule = 'always';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(tr('hardware.radio.add')),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: link,
                  decoration: InputDecoration(labelText: tr('hardware.radio.link')),
                  items: [
                    const DropdownMenuItem(
                        value: LinkFlag.lora, child: Text('LoRa')),
                    DropdownMenuItem(
                        value: LinkFlag.packetRadio,
                        child: Text(tr('hardware.link.packet_ax25'))),
                    DropdownMenuItem(
                        value: LinkFlag.bluetooth,
                        child: Text(tr('hardware.link.bluetooth'))),
                    DropdownMenuItem(
                        value: LinkFlag.wifiDirect,
                        child: Text(tr('hardware.link.wifi_direct'))),
                  ],
                  onChanged: (v) => setLocal(() => link = v ?? LinkFlag.lora),
                ),
                TextFormField(
                  initialValue: '$range',
                  decoration: InputDecoration(
                      labelText: tr('hardware.radio.range'),
                      helperText: tr('hardware.radio.range.help')),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => range = int.tryParse(v) ?? range,
                ),
                TextFormField(
                  initialValue: '$freq',
                  decoration: InputDecoration(
                    labelText: tr('hardware.radio.freq'),
                    helperText: tr('hardware.radio.freq.help'),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (v) => freq = int.tryParse(v) ?? freq,
                ),
                TextFormField(
                  initialValue: mode,
                  decoration: InputDecoration(labelText: tr('hardware.radio.mode')),
                  onChanged: (v) => mode = v,
                ),
                TextFormField(
                  initialValue: schedule,
                  decoration: InputDecoration(
                    labelText: tr('hardware.radio.schedule'),
                    helperText: tr('hardware.radio.schedule.help'),
                  ),
                  onChanged: (v) => schedule = v,
                ),
                const SizedBox(height: 8),
                Text(
                  trSchedule(ListeningSchedule.parse(schedule)),
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(tr('common.cancel'))),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(tr('common.add'))),
          ],
        ),
      ),
    );

    if (ok != true) return;
    final rs = _svc.radios
      ..removeWhere((r) => r.link == link)
      ..add(RadioEntry(
        link: link,
        rangeKm: range,
        freqKhz: freq,
        mode: mode,
        schedule: ListeningSchedule.parse(schedule),
      ));
    _save(() => _svc.radios = rs);
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

  static String _powerLabel(PowerSource p) => switch (p) {
        PowerSource.solarBattery => tr('hardware.power.solar_battery'),
        PowerSource.windHydro => tr('hardware.power.wind_hydro'),
        PowerSource.solar => tr('hardware.power.solar'),
        PowerSource.gridUps => tr('hardware.power.grid_ups'),
        PowerSource.grid => tr('hardware.power.grid'),
        PowerSource.vehicle => tr('hardware.power.vehicle'),
        PowerSource.batteryOnly => tr('hardware.power.battery'),
        PowerSource.unknown => tr('hardware.power.not_stated'),
      };

  static String _uplinkLabel(UplinkKind u) => switch (u) {
        UplinkKind.satellite => tr('hardware.uplink.satellite'),
        UplinkKind.fibre => tr('hardware.uplink.fibre'),
        UplinkKind.wifi => tr('hardware.uplink.wifi'),
        UplinkKind.cellular => tr('hardware.uplink.cellular'),
        UplinkKind.none => tr('hardware.uplink.none'),
        UplinkKind.unknown => tr('common.unknown'),
      };

  static String _linkLabel(int l) => switch (l) {
        LinkFlag.lora => 'LoRa',
        LinkFlag.packetRadio => tr('hardware.link.packet'),
        LinkFlag.bluetooth => tr('hardware.link.bluetooth'),
        LinkFlag.wifiDirect => tr('hardware.link.wifi_direct'),
        LinkFlag.serial => tr('hardware.link.serial'),
        _ => tr('hardware.link.radio'),
      };

  static IconData _linkIcon(int l) => switch (l) {
        LinkFlag.lora => Icons.settings_input_antenna,
        LinkFlag.packetRadio => Icons.radio,
        LinkFlag.bluetooth => Icons.bluetooth,
        LinkFlag.wifiDirect => Icons.wifi_tethering,
        _ => Icons.cable,
      };

  static String _freq(int khz) => khz % 1000 == 0
      ? '${khz ~/ 1000} MHz'
      : '${(khz / 1000).toStringAsFixed(3)} MHz';

  static String _bw(int cls) {
    final bps = 1 << cls;
    if (bps > 1000000) return '${(bps / 1000000).toStringAsFixed(1)} MB/s';
    if (bps > 1000) return '${(bps / 1000).toStringAsFixed(0)} kB/s';
    return '$bps B/s';
  }

  /// What a geohash of this length actually promises.
  static String _precisionKm(String g) => switch (g.length) {
        <= 2 => tr('hardware.precision.country'),
        3 => tr('hardware.precision.region'),
        4 => tr('hardware.precision.district'),
        5 => tr('hardware.precision.town'),
        _ => tr('hardware.precision.neighbourhood'),
      };
}
