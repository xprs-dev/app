// Settings > This device: the device's own X3 callsign and who owns it.
// The key is made and kept by the core (core/lib/src/profile/device_identity.dart);
// this card only shows it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xprs_core/src/profile/device_identity.dart';

import '../services/i18n/core_i18n.dart';

class DeviceIdentityCard extends StatelessWidget {
  const DeviceIdentityCard({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<void>(
      future: DeviceIdentity.instance.ensure(),
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
              owners.isEmpty
                  ? tr('settings.device.no_owner')
                  : tr('settings.device.owner', {'owner': owners.join(', ')}),
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
            trailing: IconButton(
              tooltip: tr('settings.device.copy'),
              icon: const Icon(Icons.copy),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: dev.callsign));
                ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(tr('settings.device.copied'))));
              },
            ),
          ),
        );
      },
    );
  }
}
