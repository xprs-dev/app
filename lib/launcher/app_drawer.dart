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
              ListTile(
                leading: const Icon(Icons.system_update),
                title: Text(tr('launcher.drawer.updates')),
                subtitle: Text(tr('launcher.drawer.version', {'version': kAppVersion})),
                onTap: () => _open(context, const UpdatePage()),
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
          ],
        ),
      ),
    );
  }
}
