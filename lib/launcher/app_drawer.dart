part of 'launcher.dart';

class _AppDrawer extends StatelessWidget {
  final VoidCallback onSettings;

  const _AppDrawer({required this.onSettings});

  /// Close the drawer, then push the page — same order the Settings entry
  /// uses, so the drawer is not still open when the user comes back.
  void _open(BuildContext context, Widget page) {
    Navigator.of(context).pop();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Future<void> _confirmExit(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('launcher.exit.title')),
        content: Text(tr('launcher.exit.body')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('common.cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(tr('launcher.exit.confirm'))),
        ],
      ),
    );
    if (ok == true) await exitApp();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final profile = ProfileService.instance.activeProfile;
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  if (profile != null)
                    ProfileAvatar(profile: profile, size: 44)
                  else
                    CircleAvatar(
                      backgroundColor: cs.primaryContainer,
                      child: Icon(Icons.person, color: cs.onPrimaryContainer),
                    ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      profile?.displayName ?? 'XPRS',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // The panels people reach for often, one tap from the home
            // screen. Settings still holds everything else.
            if (UpdateService.selfUpdateEnabled)
              ValueListenableBuilder<UpdateNotice>(
                valueListenable: UpdateService.instance.notice,
                builder: (context, n, _) {
                  final lit = n == UpdateNotice.ready ||
                      n == UpdateNotice.available;
                  return ListTile(
                    leading: Badge(
                      isLabelVisible: lit,
                      smallSize: 9,
                      child: const Icon(Icons.system_update),
                    ),
                    title: Text(tr('launcher.drawer.updates')),
                    subtitle: Text(
                      n == UpdateNotice.ready
                          ? tr('launcher.drawer.update_ready')
                          : n == UpdateNotice.available
                              ? tr('launcher.drawer.update_available')
                              : tr('launcher.drawer.version',
                                  {'version': kAppVersion}),
                      style: lit ? TextStyle(color: cs.primary) : null,
                    ),
                    onTap: () => _open(context, const UpdatePage()),
                  );
                },
              ),
            ListTile(
              leading: const Icon(Icons.memory),
              title: Text(tr('launcher.drawer.hardware')),
              onTap: () => _open(context, const HardwarePage()),
            ),
            ListTile(
              leading: const Icon(Icons.groups),
              title: Text(tr('launcher.drawer.groups')),
              onTap: () => _open(context, const GroupsPage()),
            ),
            if (platform.platformName() == 'android')
              ListTile(
                leading: const Icon(Icons.share),
                title: Text(tr('common.share')),
                onTap: () => _open(context, const ShareAppPage()),
              ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.settings),
              title: Text(tr('common.settings')),
              onTap: onSettings,
            ),
            // Exit sits apart at the bottom: it stops the background service
            // too, so nothing is received or relayed until XPRS is opened
            // again. A browser tab is closed by the browser.
            if (!kIsWeb) ...[
              const Spacer(),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.power_settings_new),
                title: Text(tr('launcher.drawer.exit')),
                onTap: () => _confirmExit(context),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
