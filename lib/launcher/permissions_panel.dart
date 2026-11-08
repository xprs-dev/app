part of 'launcher.dart';

/// The permission rows, shared by the first-run intro and Settings >
/// Permissions: each row's live state, what it enables, what stops working
/// without it, and a Grant button (Open settings once Android stopped asking).
///
/// Nothing here is mandatory. Every grant refreshes PermissionState, so a
/// feature waiting on a permission (the Bluetooth radio, WiFi Direct) starts
/// the moment it arrives, with no restart.
class PermissionsPanel extends StatefulWidget {
  /// Called after every refresh with whether everything is granted.
  final void Function(bool allGranted)? onChanged;
  const PermissionsPanel({super.key, this.onChanged});

  @override
  State<PermissionsPanel> createState() => _PermissionsPanelState();
}

class _PermissionsPanelState extends State<PermissionsPanel>
    with WidgetsBindingObserver {
  final Map<String, bool> _granted = {};
  final Set<String> _blocked = {}; // refused with "don't ask again"
  List<AppPermission> _shown = const [];
  bool _busy = false;
  bool _allGranted = false;
  bool? _locationSwitch = true;
  int _sdk = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Special-access grants (All files, battery) and "Open settings" leave
    // the app; re-read when the person comes back.
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    final svc = AndroidPermissionsService.instance;
    final shown = await svc.shownItems();
    final granted = <String, bool>{};
    final blocked = <String>{};
    for (final item in shown) {
      granted[item.key] = await svc.isGranted(item);
      if (granted[item.key] == false && await svc.isPermanentlyDenied(item)) {
        blocked.add(item.key);
      }
    }
    final all = await svc.allGranted();
    final sw = await svc.locationServicesState();
    final sdk = await platform.androidSdkInt();
    await PermissionState.instance.refresh();
    if (!mounted) return;
    setState(() {
      _shown = shown;
      _granted
        ..clear()
        ..addAll(granted);
      _blocked
        ..clear()
        ..addAll(blocked);
      _allGranted = all;
      _locationSwitch = sw;
      _sdk = sdk;
    });
    widget.onChanged?.call(all);
  }

  Future<void> _grant(AppPermission item) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await AndroidPermissionsService.instance.requestItem(item);
    } catch (_) {}
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _grantAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await AndroidPermissionsService.instance.requestAll();
    } catch (_) {}
    await _refresh();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(tr('permissions.title'),
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const Spacer(),
            Text(
              tr(_allGranted
                  ? 'permissions.all_granted'
                  : 'permissions.tap_to_grant'),
              style: theme.textTheme.labelMedium?.copyWith(
                color: _allGranted ? Colors.green : cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          tr('permissions.intro'),
          style:
              theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 16),
        // Grant-all sits ABOVE the list: it is what almost everyone wants,
        // and below a full-height list it was off-screen.
        if (!_allGranted) ...[
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : _grantAll,
              icon: const Icon(Icons.done_all, size: 18),
              label: Text(tr('permissions.grant_all')),
            ),
          ),
          const SizedBox(height: 16),
        ],
        for (final item in _shown) _row(theme, item),
      ],
    );
  }

  static IconData _iconFor(String name) {
    switch (name) {
      case 'bluetooth':
        return Icons.bluetooth;
      case 'notifications':
        return Icons.notifications_outlined;
      case 'folder':
        return Icons.folder_outlined;
      case 'wifi':
        return Icons.wifi;
      case 'location':
        return Icons.location_on_outlined;
      case 'battery':
        return Icons.battery_charging_full;
      default:
        return Icons.check_circle_outline;
    }
  }

  Widget _row(ThemeData theme, AppPermission item) {
    final cs = theme.colorScheme;
    final granted = item.info || (_granted[item.key] ?? false);
    final small = theme.textTheme.bodySmall;
    // The Location switch is separate from the permission; say so under the
    // row, and on Android 11 and older that Bluetooth scans depend on it.
    final switchOff = item.key == 'location' && _locationSwitch == false;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_iconFor(item.icon), size: 20, color: cs.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Rows are named by key: the service keeps the English for
                // logs; this screen reads the person's language.
                Text(tr('permissions.${item.key}.title'),
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text(tr('permissions.${item.key}.desc'),
                    style: small?.copyWith(color: cs.onSurfaceVariant)),
                if (!granted)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(tr('permissions.${item.key}.without'),
                        style: small?.copyWith(color: cs.tertiary)),
                  ),
                if (switchOff)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                        tr(_sdk != 0 && _sdk <= 30
                            ? 'permissions.location.switch_off_ble'
                            : 'permissions.location.switch_off'),
                        style: small?.copyWith(color: cs.tertiary)),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Informational rows and granted rows both read as "you have this",
          // so both get the same green check.
          if (granted && !switchOff)
            const Icon(Icons.check_circle, size: 22, color: Colors.green)
          else
            TextButton(
              onPressed: _busy
                  ? null
                  : (granted
                      ? () => Geolocator.openLocationSettings()
                      : () => _grant(item)),
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                minimumSize: Size.zero,
              ),
              child: Text(tr(granted || _blocked.contains(item.key)
                  ? 'permissions.open_settings'
                  : 'permissions.grant')),
            ),
        ],
      ),
    );
  }
}

/// Settings > Permissions: the same rows as the intro, any time later.
class PermissionsPage extends StatelessWidget {
  const PermissionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('permissions.title'))),
      body: const SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(20),
          child: PermissionsPanel(),
        ),
      ),
    );
  }
}
