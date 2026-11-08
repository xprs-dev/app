part of 'launcher.dart';

/// First-run Android intro: explains and offers every permission XPRS uses,
/// with each one's live state and what stops working without it. Shown once
/// (the stored onboarding flag); the person may continue with any subset, and
/// Settings > Permissions offers the same rows later. Skipped on non-Android
/// platforms (no runtime permissions).
class PermissionsIntroPage extends StatefulWidget {
  final Future<void> Function() onComplete;
  const PermissionsIntroPage({super.key, required this.onComplete});

  @override
  State<PermissionsIntroPage> createState() => _PermissionsIntroPageState();
}

class _PermissionsIntroPageState extends State<PermissionsIntroPage> {
  bool _busy = false;
  bool _allGranted = false;

  Future<void> _continue() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onComplete();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: cs.primaryContainer,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(Icons.travel_explore,
                          size: 36, color: cs.onPrimaryContainer),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tr('permissions.welcome'),
                              style: theme.textTheme.titleLarge
                                  ?.copyWith(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text(
                            tr('permissions.tagline'),
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(color: cs.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                PermissionsPanel(
                  onChanged: (all) {
                    if (mounted && all != _allGranted) {
                      setState(() => _allGranted = all);
                    }
                  },
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.secondaryContainer.withAlpha(128),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.privacy_tip_outlined,
                          size: 20, color: cs.secondary),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          tr('permissions.privacy'),
                          style: theme.textTheme.bodySmall
                              ?.copyWith(color: cs.onSecondaryContainer),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    // Never disabled: every permission is optional, and the
                    // app runs with whatever was granted (PermissionState).
                    // The label only says which of the two it will be.
                    onPressed: _busy ? null : _continue,
                    child: _busy
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(tr(_allGranted
                            ? 'common.continue'
                            : 'permissions.continue_limited')),
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
