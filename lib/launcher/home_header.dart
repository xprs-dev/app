part of 'launcher.dart';

class _HomeHeader extends StatelessWidget implements PreferredSizeWidget {
  final VoidCallback onMenu;
  final VoidCallback onNotifications;
  final VoidCallback? onMail;
  final VoidCallback? onChat;
  final WappManifest? mailWapp;
  final WappManifest? chatWapp;

  const _HomeHeader({
    required this.onMenu,
    required this.onNotifications,
    this.onMail,
    this.onChat,
    this.mailWapp,
    this.chatWapp,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.menu),
        tooltip: 'Menu',
        onPressed: onMenu,
      ),
      titleSpacing: 0,
      title: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ProfileSwitcher(),
          SizedBox(width: 10),
          _ConnectionIndicator(),
        ],
      ),
      actions: [
        ValueListenableBuilder<int>(
          valueListenable: NotificationStore.instance.unreadCount,
          builder: (context, count, _) => _BadgedActionIcon(
            icon: Icons.notifications_none,
            tooltip: 'Notifications',
            count: count,
            onPressed: onNotifications,
          ),
        ),
        if (mailWapp != null && onMail != null)
          _IntentBadgeIcon(
            icon: Icons.mail_outline,
            tooltip: 'Mail',
            wappId: BackgroundWappManager.folderName(mailWapp!.dirPath),
            intent: 'mail',
            onPressed: onMail!,
          ),
        if (chatWapp != null && onChat != null)
          _IntentBadgeIcon(
            icon: Icons.forum_outlined,
            tooltip: 'Chat',
            wappId: BackgroundWappManager.folderName(chatWapp!.dirPath),
            intent: 'chat',
            onPressed: onChat!,
          ),
        const SizedBox(width: 6),
      ],
    );
  }
}

/// A host icon (Mail, Chat) badged with its wapp's unread count.
///
/// The count comes from ONE authority: the wapp's own unread, via
/// [WappUnreadService.badgeFor]. It used to add `RnsService.lxmfUnreadCount`
/// on top, which counted the same inbound DMs a second time -- the chat wapp
/// files every accepted LXMF message into a `lxmf:<dest>` conversation, and
/// that conversation's unread is the copy that is persisted and that clearing
/// a conversation actually clears.
class _IntentBadgeIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final String wappId;
  final String intent;
  final VoidCallback onPressed;

  const _IntentBadgeIcon({
    required this.icon,
    required this.tooltip,
    required this.wappId,
    required this.intent,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, int>>(
      valueListenable: WappUnreadService.instance.counts,
      builder: (context, _, child) => _BadgedActionIcon(
        icon: icon,
        tooltip: tooltip,
        count: WappUnreadService.instance.badgeFor(wappId, intent),
        onPressed: onPressed,
      ),
    );
  }
}

class _BadgedActionIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final int count;
  final VoidCallback onPressed;

  const _BadgedActionIcon({
    required this.icon,
    required this.tooltip,
    required this.count,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(icon: Icon(icon), tooltip: tooltip, onPressed: onPressed),
        if (count > 0)
          Positioned(
            right: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              constraints: const BoxConstraints(minWidth: 17),
              decoration: BoxDecoration(
                color: const Color(0xFFda3633),
                borderRadius: BorderRadius.circular(9),
              ),
              alignment: Alignment.center,
              child: Text(
                count > 99 ? '99+' : '$count',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
