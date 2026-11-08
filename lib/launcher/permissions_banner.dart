part of 'launcher.dart';

/// One quiet line on the home screen while Bluetooth is not allowed: the
/// nearby mesh is the feature a refused permission costs most, and nothing
/// else on the home screen would say why no one nearby shows up. Opens
/// Settings > Permissions. Dismissed per refused set: refusing something
/// else later shows it again.
class _PermissionBanner extends StatefulWidget {
  const _PermissionBanner();

  @override
  State<_PermissionBanner> createState() => _PermissionBannerState();
}

class _PermissionBannerState extends State<_PermissionBanner> {
  String _dismissed = '';
  PreferencesService? _prefs;

  @override
  void initState() {
    super.initState();
    PreferencesService.instance().then((p) {
      if (!mounted) return;
      setState(() {
        _prefs = p;
        _dismissed = p.permissionsBannerDismissed;
      });
    });
  }

  static String _key(Set<String> missing) => (missing.toList()..sort()).join(',');

  @override
  Widget build(BuildContext context) {
    if (platform.platformName() != 'android') return const SizedBox.shrink();
    return ValueListenableBuilder<bool>(
      valueListenable: PermissionState.instance.bluetooth.listenable,
      builder: (context, bluetooth, _) {
        final missing = PermissionState.instance.missing.value;
        if (bluetooth ||
            !PermissionState.instance.refreshed ||
            _prefs == null ||
            _dismissed == _key(missing)) {
          return const SizedBox.shrink();
        }
        final cs = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Material(
            color: cs.tertiaryContainer.withAlpha(140),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const PermissionsPage())),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                child: Row(
                  children: [
                    Icon(Icons.bluetooth_disabled,
                        size: 20, color: cs.onTertiaryContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(tr('permissions.banner.bluetooth'),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: cs.onTertiaryContainer)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      tooltip: tr('common.close'),
                      onPressed: () {
                        final k = _key(missing);
                        setState(() => _dismissed = k);
                        _prefs?.setPermissionsBannerDismissed(k);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
