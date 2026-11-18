// The device's own X3 callsign and who owns it (Settings > This device, and
// the Archiver page, where it is the archiver's name), with a way to pick a
// different one. The key is made and kept by the core
// (core/lib/src/profile/device_identity.dart); this card shows it and hands the
// core the one the person picked.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xprs_core/src/profile/device_identity.dart';

import '../boot/app_exit.dart';
import '../services/i18n/core_i18n.dart';
import '../services/preferences_service.dart';

class DeviceIdentityCard extends StatefulWidget {
  const DeviceIdentityCard({super.key});

  @override
  State<DeviceIdentityCard> createState() => _DeviceIdentityCardState();
}

class _DeviceIdentityCardState extends State<DeviceIdentityCard> {
  late final Future<void> _ready = DeviceIdentity.instance.ensure();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<void>(
      future: _ready,
      builder: (context, _) {
        final dev = DeviceIdentity.instance;
        if (!dev.ready) return const SizedBox.shrink();
        final owners = dev.owners();
        return Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            leading: const Icon(Icons.router_outlined),
            title: Text(dev.callsign,
                style: const TextStyle(
                    fontFamily: 'monospace', fontWeight: FontWeight.w600)),
            subtitle: Text(
              [
                owners.isEmpty
                    ? tr('settings.device.no_owner')
                    : tr('settings.device.owner',
                        {'owner': owners.join(', ')}),
                // The device's X3 is the archiver: say so where the person
                // switched the role on, so the callsign others choose is
                // the one shown here.
                if (PreferencesService.instanceSync?.xprsPublicArchiver ??
                    false)
                  tr('settings.device.archiver'),
              ].join('\n'),
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: tr('settings.device.copy'),
                  icon: const Icon(Icons.copy),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: dev.callsign));
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(tr('settings.device.copied'))));
                  },
                ),
                if (!dev.isProfileKey)
                  IconButton(
                    tooltip: tr('settings.device.change'),
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () async {
                      if (await changeStationCallsign(context) && mounted) {
                        setState(() {});
                      }
                    },
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Let the person pick the station's callsign: a fresh one, another, back to
/// the one before, then Save. The callsign is derived from the key (XPRS.md
/// 3), so each candidate is a new key, made here and kept only when saved.
/// Returns true when a new callsign was saved.
Future<bool> changeStationCallsign(BuildContext context) async {
  final dev = DeviceIdentity.instance;
  await dev.ensure();
  if (!dev.ready || dev.isProfileKey || !context.mounted) return false;
  final picked = await showDialog<String>(
    context: context,
    builder: (_) => _StationCallsignDialog(current: dev.callsign),
  );
  if (picked == null || !context.mounted) return false;
  final String call;
  try {
    call = await dev.replace(picked);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(tr('settings.device.change.failed'))));
    }
    return false;
  }
  if (!context.mounted) return true;
  // Everything reads the callsign live except the names the mesh answers to,
  // gathered at start-up: offer the restart that makes it whole.
  final restart = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(tr('settings.device.change.saved', {'callsign': call})),
      content: Text(tr('settings.device.change.restart')),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('settings.device.change.later'))),
        FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('launcher.exit.confirm'))),
      ],
    ),
  );
  if (restart == true) await exitApp();
  return true;
}

class _StationCallsignDialog extends StatefulWidget {
  const _StationCallsignDialog({required this.current});
  final String current;

  @override
  State<_StationCallsignDialog> createState() => _StationCallsignDialogState();
}

class _StationCallsignDialogState extends State<_StationCallsignDialog> {
  /// Candidates shown so far, newest last; undo walks back through them.
  final List<({String callsign, String npub, String nsec})> _seen = [
    DeviceIdentity.candidate(),
  ];

  ({String callsign, String npub, String nsec}) get _shown => _seen.last;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    return AlertDialog(
      title: Text(tr('settings.device.change.title')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(tr('settings.device.change.now', {'callsign': widget.current}),
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: tr('settings.device.change.back'),
                  icon: const Icon(Icons.undo),
                  onPressed: _seen.length > 1
                      ? () => setState(() => _seen.removeLast())
                      : null,
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: Text(
                      _shown.callsign,
                      key: ValueKey(_shown.callsign),
                      textAlign: TextAlign.center,
                      style: tt.headlineSmall?.copyWith(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                          letterSpacing: 2),
                    ),
                  ),
                ),
                IconButton.filledTonal(
                  tooltip: tr('settings.device.change.another'),
                  icon: const Icon(Icons.autorenew),
                  onPressed: () =>
                      setState(() => _seen.add(DeviceIdentity.candidate())),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Text(tr('settings.device.change.note'),
              style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(tr('common.cancel'))),
        FilledButton(
            onPressed: () => Navigator.pop(context, _shown.nsec),
            child: Text(tr('common.save'))),
      ],
    );
  }
}
