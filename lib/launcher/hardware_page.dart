import 'package:flutter/material.dart';
import 'package:reticulum/src/services/social/listening_schedule.dart';
import 'package:reticulum/src/services/social/node_profile.dart';

import '../services/i18n/schedule_text.dart';

import '../services/preferences_service.dart';
import '../services/social/node_profile_service.dart';
import '../services/i18n/core_i18n.dart';

/// Settings → Hardware: what this device is made of (docs/NOSTR.md).
///
/// Stated ONCE, for the device, and read by every role — a box volunteered as
/// both an Archiver and an Archiver must not be asked twice what it is plugged
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
                  label: tr('hardware.autonomy.hours',
                      {'n': p.nodeAutonomyHours}),
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
              // Shown once there is a measurement: until something has been
              // timed, "not measured yet" was all this line could ever say.
              if (profile.bwClass > 0)
                _measured(
                  cs,
                  tr('hardware.speed.observed', {'bw': _bw(profile.bwClass)}),
                  tr('hardware.speed.why'),
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
                  title: Text(r.rangeKm > 0
                      ? '${_linkLabel(r.link)} · ${r.rangeKm} km'
                      : _linkLabel(r.link)),
                  subtitle: Text([
                    if (r.freqKhz > 0) _freq(r.freqKhz),
                    if (r.mode.isNotEmpty) r.mode,
                    trSchedule(r.schedule),
                  ].join(' · ')),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline),
                    tooltip: tr('common.delete'),
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

  /// What a new radio of [link] starts from: LoRa on 868.2 MHz, packet on
  /// the 2 m APRS frequency, and no frequency or mode for Bluetooth and WiFi
  /// Direct, which have neither to state.
  static ({int range, int freq, String mode}) _radioDefaults(int link) =>
      switch (link) {
        LinkFlag.lora => (range: 5, freq: 868200, mode: 'LoRa-SF7BW125'),
        LinkFlag.packetRadio => (range: 30, freq: 144800, mode: 'AX.25 1200'),
        _ => (range: 0, freq: 0, mode: ''),
      };

  static bool _hasFrequency(int link) =>
      link == LinkFlag.lora || link == LinkFlag.packetRadio;

  Future<void> _addRadio() async {
    var link = LinkFlag.lora;
    var d = _radioDefaults(link);
    final range = TextEditingController(text: '${d.range}');
    final freq = TextEditingController(text: '${d.freq}');
    final mode = TextEditingController(text: d.mode);
    final schedule = TextEditingController(text: 'always');

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
                  // Another kind of radio starts from its own defaults: a
                  // Bluetooth link kept LoRa's 868 MHz before.
                  onChanged: (v) => setLocal(() {
                    link = v ?? LinkFlag.lora;
                    d = _radioDefaults(link);
                    range.text = '${d.range}';
                    freq.text = '${d.freq}';
                    mode.text = d.mode;
                  }),
                ),
                TextFormField(
                  controller: range,
                  decoration: InputDecoration(
                      labelText: tr('hardware.radio.range'),
                      helperText: tr('hardware.radio.range.help')),
                  keyboardType: TextInputType.number,
                ),
                if (_hasFrequency(link)) ...[
                  TextFormField(
                    controller: freq,
                    decoration: InputDecoration(
                      labelText: tr('hardware.radio.freq'),
                      helperText: tr('hardware.radio.freq.help'),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  TextFormField(
                    controller: mode,
                    decoration:
                        InputDecoration(labelText: tr('hardware.radio.mode')),
                  ),
                ],
                TextFormField(
                  controller: schedule,
                  decoration: InputDecoration(
                    labelText: tr('hardware.radio.schedule'),
                    helperText: tr('hardware.radio.schedule.help'),
                  ),
                  // The reading below follows what is typed.
                  onChanged: (_) => setLocal(() {}),
                ),
                const SizedBox(height: 8),
                Text(
                  trSchedule(ListeningSchedule.parse(schedule.text)),
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

    final hasFreq = _hasFrequency(link);
    final entry = RadioEntry(
      link: link,
      rangeKm: int.tryParse(range.text.trim()) ?? d.range,
      freqKhz: hasFreq ? (int.tryParse(freq.text.trim()) ?? d.freq) : 0,
      mode: hasFreq ? mode.text.trim() : '',
      schedule: ListeningSchedule.parse(schedule.text.trim()),
    );
    for (final c in [range, freq, mode, schedule]) {
      c.dispose();
    }
    if (ok != true) return;
    final rs = _svc.radios
      ..removeWhere((r) => r.link == link)
      ..add(entry);
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
}
