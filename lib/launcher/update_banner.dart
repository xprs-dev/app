part of 'launcher.dart';

/// One line on the home screen while a downloaded update waits to be
/// installed. Opens Updates, where Install is the one button.
class _UpdateReadyBanner extends StatelessWidget {
  const _UpdateReadyBanner();

  @override
  Widget build(BuildContext context) {
    if (!UpdateService.selfUpdateEnabled) return const SizedBox.shrink();
    final svc = UpdateService.instance;
    return ValueListenableBuilder<UpdateNotice>(
      valueListenable: svc.notice,
      builder: (context, n, _) {
        if (n != UpdateNotice.ready) return const SizedBox.shrink();
        final cs = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Material(
            color: cs.primaryContainer.withAlpha(160),
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const UpdatePage())),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                child: Row(
                  children: [
                    Icon(Icons.system_update_alt,
                        size: 20, color: cs.onPrimaryContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                          tr('notifications.update.ready',
                              {'version': svc.readyVersion ?? ''}),
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: cs.onPrimaryContainer)),
                    ),
                    Icon(Icons.chevron_right,
                        size: 18, color: cs.onPrimaryContainer),
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
