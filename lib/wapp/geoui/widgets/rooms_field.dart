import 'package:flutter/material.dart';

import '../conversation_store.dart';
import '../../../services/xprs/xprs_monitor.dart';
import '../../../services/reticulum/rns_service.dart';
import '../../../profile/station_avatar.dart';
import 'chat_palette.dart';
import 'chat_view_field.dart';
import 'people_view_field.dart';

/// `$type:"rooms"` — a Discord-like chat layout, driven entirely by the wapp.
///
/// A thin left icon rail of rooms that expands on a left→right drag into a panel
/// of room names + the nested sub-room tree (a `+` creates a room, a bottom gear
/// opens settings); a center chat pane; and a member list that slides in from the
/// right. The widget is app-agnostic: it renders the room list, chat messages and
/// members it is given, and reports taps back. NIP-72 / moderation semantics live
/// in the wapp.
///
/// Data in: `ui.rooms.set {rooms:[{id,name,icon,parent,depth,unread,selected}]}`
/// for the rail, the usual `ui.convo.*` for the open room's messages, and
/// `ui.people.set` (field `room_members`) for the member panel.
class RoomsField extends StatefulWidget {
  /// Rail rooms, pre-ordered (root first, children after their parent).
  final List<Map<String, dynamic>> rooms;

  /// Message store; the open room's messages are `store.items[openId]?.messages`.
  final ConversationStore store;

  /// The selected room id (whose chat is shown), or null.
  final String? openId;

  /// `ui.people.set` sections for the right-side member list.
  final List<Map<String, dynamic>> memberSections;

  final void Function(String id) onOpenRoom;
  final void Function(String id, String text) onSend;
  final void Function(String parentId) onNewRoom;

  /// "New chat" — find a PERSON (NomadNet/LXMF peer, callsign, npub) and start
  /// a direct conversation. Distinct from onNewRoom, which creates a place.
  final VoidCallback? onNewChat;

  final void Function(String id) onMemberTap;
  final void Function(String from)? onSenderTap;
  final void Function(String mid)? onReveal;

  /// Flip the private/plain form for the next message (docs/XPRS.md 9.2).
  final VoidCallback? onTogglePrivacy;
  final bool privacyOn;

  /// Long-press bubble actions, same contract as the conversations widget:
  /// hide one message (by its content key) / block its sender. The rooms
  /// layout embeds the same chat view, and without these the ONLY layout most
  /// users see had no way to make a spammy sender go away.
  final void Function(String id, String key)? onHide;
  final void Function(String from)? onBlock;

  /// "Message <sender> directly" from a room bubble: the host asks the wapp to
  /// open (or create) the 1:1 with that callsign.
  final void Function(String from)? onDirectMessage;

  /// Pick a file to send with the next message. Returns the `file:` token the
  /// core minted for it, or null when the user backed out. The rooms layout is
  /// the one most people ever see, and without this it was the only chat in
  /// the app that could not send a picture.
  final Future<String?> Function()? onAttach;

  /// Conversations the person archived, and how many of them hold unread.
  /// When there are any, an "Archived" row heads the list and [onArchived]
  /// opens them.
  final int archivedCount;
  final int archivedUnread;
  final VoidCallback? onArchived;

  /// The three-dots menu on a row: archive the conversation, or delete it.
  final void Function(String id)? onArchive;
  final void Function(String id)? onDelete;

  /// Statuses at the head of the list, the way Telegram heads it with
  /// stories: this station's callsign, then the newest status of each person
  /// it talks with, `{id, call, text, ts, mine, seen}`. The wapp decides who is
  /// in it; this only draws it, posts through [onPostStatus] and reports an
  /// opened one through [onStatusSeen]. No callback, no box.
  final String me;
  final List<Map<String, dynamic>> statuses;
  final void Function(String text)? onPostStatus;
  final void Function(String id)? onStatusSeen;

  const RoomsField({
    super.key,
    this.onTogglePrivacy,
    this.privacyOn = true,
    required this.rooms,
    required this.store,
    required this.openId,
    required this.memberSections,
    required this.onOpenRoom,
    required this.onSend,
    required this.onNewRoom,
    this.onNewChat,
    required this.onMemberTap,
    this.onSenderTap,
    this.onReveal,
    this.onHide,
    this.onBlock,
    this.onDirectMessage,
    this.onAttach,
    this.archivedCount = 0,
    this.archivedUnread = 0,
    this.onArchived,
    this.onArchive,
    this.onDelete,
    this.me = '',
    this.statuses = const [],
    this.onPostStatus,
    this.onStatusSeen,
  });

  @override
  State<RoomsField> createState() => _RoomsFieldState();
}

class _RoomsFieldState extends State<RoomsField> {
  static const double _collapsed = 64;
  static const double _expanded = 248;
  static const double _threshold = 150;
  double _railW = _collapsed;
  bool _membersOpen = false;

  bool get _railExpanded => _railW > _threshold;

  final _statusInput = TextEditingController();

  @override
  void dispose() {
    _statusInput.dispose();
    super.dispose();
  }

  void _dragUpdate(DragUpdateDetails d) {
    _userSized = true; // the user's width choice outranks the auto sizing
    setState(() => _railW = (_railW + d.delta.dx).clamp(_collapsed, _expanded));
  }

  void _dragEnd(DragEndDetails d) {
    setState(() => _railW = _railExpanded ? _expanded : _collapsed);
  }

  /// Wide layouts open with the rail EXPANDED (names visible); narrow ones
  /// collapse it, because there the rail OVERLAYS the chat and an expanded
  /// one hides the conversation you just opened. Re-evaluated whenever the
  /// width crosses the threshold (a resized desktop window is the same
  /// problem as a phone), but the user's own drag wins from then on.
  bool _userSized = false;
  double? _autoW;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // Tell the store which room is on screen, exactly as ConversationsField
    // does. Without it the store believed NOTHING was open, so a message
    // arriving in the very thread the user was reading bumped its unread
    // badge — a "1" sitting on the row you are looking at.
    widget.store.openId = widget.openId;
    final open = widget.openId;
    if (open != null) widget.store.clearUnread(open);
    return LayoutBuilder(
      builder: (ctx, c) {
        if (!_userSized) {
          final want = c.maxWidth >= 900 ? _expanded : _collapsed;
          if (_autoW != want) {
            _autoW = want;
            _railW = want;
          }
        }
        if (c.maxWidth >= 640) return _wide(cs);
        return _narrow(cs, c.maxWidth);
      },
    );
  }

  Widget _railBox(ColorScheme cs) => GestureDetector(
    onHorizontalDragUpdate: _dragUpdate,
    onHorizontalDragEnd: _dragEnd,
    behavior: HitTestBehavior.opaque,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: _railW,
      color: ChatPalette.windowBg,
      child: _rail(cs),
    ),
  );

  // Wide (tablet/desktop): all three panes side by side.
  Widget _wide(ColorScheme cs) {
    return Row(
      children: [
        _railBox(cs),
        const VerticalDivider(
            width: 1, thickness: 1, color: ChatPalette.divider),
        Expanded(child: _chat(cs)),
        AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          width: _membersOpen ? 260 : 0,
          child: _membersOpen
              ? Row(
                  children: [
                    const VerticalDivider(
                        width: 1, thickness: 1, color: ChatPalette.divider),
                    Expanded(
                      child: Material(
                          color: ChatPalette.windowBg, child: _members(cs)),
                    ),
                  ],
                )
              : null,
        ),
      ],
    );
  }

  // Narrow (phone): the chat keeps full width behind a collapsed rail; the
  // expanded rail and the member panel OVERLAY it (Discord-mobile style) with a
  // tap-to-close scrim, so the chat is never squeezed.
  // Narrow (phone): the standard list<->detail pattern. No room open — the
  // conversation list fills the screen. A room open — the chat fills the
  // screen, and the ONE back arrow (the wapp AppBar's, wired by the host)
  // returns to the list. The old layout kept a collapsed rail beside the chat
  // and grew a second arrow in the thread header; two stacked back buttons
  // with different meanings helped nobody.
  Widget _narrow(ColorScheme cs, double maxW) {
    final panelW = (maxW * 0.82).clamp(220.0, 340.0);
    if (widget.openId == null) {
      _railW = _expanded; // list fills the screen
      return Material(color: ChatPalette.windowBg, child: _rail(cs));
    }
    // Back closes what is on top: the member panel first; with it closed the
    // pop propagates to the host, which closes the room back to the list.
    return PopScope(
      canPop: !_membersOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        setState(() => _membersOpen = false);
      },
      child: Stack(
        children: [
          Positioned.fill(child: _chat(cs)),
          if (_membersOpen)
            Positioned.fill(
              child: GestureDetector(
                onTap: () => setState(() => _membersOpen = false),
                child: Container(color: Colors.black.withValues(alpha: 0.45)),
              ),
            ),
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: _membersOpen ? panelW : 0,
              child: _membersOpen
                  ? Material(color: ChatPalette.windowBg, child: _members(cs))
                  : null,
            ),
          ),
        ],
      ),
    );
  }

  Widget _rail(ColorScheme cs) {
    final expanded = _railExpanded;
    return SafeArea(
      right: false,
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              children: [
                if (widget.onPostStatus != null) _statusHeader(cs, expanded),
                if (widget.archivedCount > 0 && widget.onArchived != null)
                  _archivedTile(expanded),
                for (final r in _byRecency()) _roomTile(cs, r, expanded),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Rail rows, most recently active first — the rail's job is to lead with
  /// what you actually use, and it used to render subscription order, so a
  /// conversation you had never opened sat above the one you were in.
  ///
  /// The store is the authority within a session (it stamps `activityTs` on
  /// every message and unread); the wapp's `seen` (epoch seconds, persisted)
  /// carries the order across a restart, when the store's messages are
  /// reloaded but its timestamps are older than the app itself.
  List<Map<String, dynamic>> _byRecency() {
    final rows = [...widget.rooms];
    int rank(Map<String, dynamic> r) {
      final id = '${r['id'] ?? ''}';
      final ts = widget.store.items[id]?.activityTs ?? 0;
      if (ts > 0) return ts;
      final seen = (r['seen'] as num?)?.toInt() ?? 0;
      return seen > 0 ? seen * 1000 : 0; // wapp reports epoch SECONDS
    }

    return roomsTreeByRank(rows, rank);
  }


  /// "2m" / "4h" / "yd" / "3d" — a chat list wants an age, not a clock.
  static String _ago(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(ms),
    );
    if (d.inMinutes < 1) return 'now';
    if (d.inMinutes < 60) return '${d.inMinutes}m';
    if (d.inHours < 24) return '${d.inHours}h';
    if (d.inDays == 1) return 'yd';
    if (d.inDays < 7) return '${d.inDays}d';
    return '${(d.inDays / 7).floor()}w';
  }

  Widget _roomTile(ColorScheme cs, Map<String, dynamic> r, bool expanded) {
    final id = '${r['id'] ?? ''}';
    if (id.isEmpty) return const SizedBox.shrink();
    final name = '${r['name'] ?? id}';
    final depth = (r['depth'] as num?)?.toInt() ?? 0;
    // The wapp rarely knows the unread count — the conversation store does
    // (it tracks arrivals against the open room). Fall back to it, so a room
    // or channel with waiting messages actually says so on the rail.
    final unread =
        (r['unread'] as num?)?.toInt() ?? widget.store.items[id]?.unread ?? 0;
    final selected = r['selected'] == true || id == widget.openId;
    final item = widget.store.items[id];
    // Reachability is the core's, not the wapp's: a callsign room is "live"
    // when the station is heard on the air OR reachable over the internet --
    // the same test the header dot uses; a '#room' has no single peer.
    final live = !id.startsWith('#') &&
        (XprsMonitor.instance.heardRecently(id) ||
            RnsService.instance.reachableByCallsign(id));

    // The second line: what was last said here, else what this place IS.
    // "N people seen" is the wapp's count of DISTINCT senders observed — never
    // a membership roster, which neither rooms nor LXMF groups publish.
    // Newest message that is actually a message. A like arrives as a
    // "<mid>:like" vote and is filtered out of the timeline — quoting one as
    // the preview would show a hex blob as the last thing anybody said.
    // The stored preview, written when the message arrived. Deriving it here
    // meant every room on the rail had to have its messages loaded, which is
    // the whole history in the database for a line of text per row.
    var lastMsg = item?.lastLine ?? '';
    // A room already open (its tail is in memory) can still refine it — and an
    // older row written before lastLine existed has nothing else to fall back
    // on until its next message.
    for (final m in (lastMsg.isNotEmpty ? const [] : (item?.messages ?? const []))
        .reversed) {
      final text = (m['text'] ?? '').toString().trim();
      if (text.isEmpty) continue;
      if (RegExp(r'^[0-9a-f]{8,64}:(?:un)?like$').hasMatch(text)) continue;
      if (m['sys'] == true) continue;
      final from = (m['from'] ?? '').toString();
      lastMsg = from.isEmpty ? text : '$from: $text';
      break;
    }
    final people = (r['people'] as num?)?.toInt() ?? 0;
    var sub = lastMsg.isNotEmpty
        ? lastMsg
        : (item?.subtitle.isNotEmpty ?? false ? item!.subtitle : '');
    if (sub.isEmpty && people > 0) {
      sub = people == 1 ? '1 person seen' : '$people people seen';
    }
    if (sub.startsWith(': ')) sub = sub.substring(2);

    final ts = item?.activityTs ?? 0;
    final seenSec = (r['seen'] as num?)?.toInt() ?? 0;
    final age = _ago(ts > 0 ? ts : seenSec * 1000);

    var icon = _avatar(cs, id, name, selected, expanded ? 48 : 44);
    // Collapsed rail: there is no row space beside a 44px avatar in a 64px
    // rail, so the count rides ON the avatar as a corner chip (a badge in the
    // row overflowed it). Expanded keeps the inline pill next to the name.
    if (!expanded && unread > 0) {
      icon = Stack(
        clipBehavior: Clip.none,
        children: [
          icon,
          Positioned(
            top: -3,
            right: -3,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
              constraints: const BoxConstraints(minWidth: 16),
              decoration: BoxDecoration(
                color: ChatPalette.accent,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: ChatPalette.windowBg, width: 1.5),
              ),
              child: Text(
                unread > 99 ? '99+' : '$unread',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: ChatPalette.onAccent,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      );
    }
    final hasMenu = widget.onArchive != null || widget.onDelete != null;
    final tile = InkWell(
      // Right-click on a desktop, long-press on a phone (below): the same
      // menu as the three dots, which the collapsed rail has no room for.
      onSecondaryTapUp: hasMenu
          ? (d) => _menuAt(d.globalPosition, id, name)
          : null,
      onTap: () {
        widget.onOpenRoom(id);
        // Narrow: the expanded rail is an overlay ON the chat, so picking a
        // conversation has to get out of the way — otherwise you tap a room
        // and still see the list.
        if (MediaQuery.of(context).size.width < 900 && _railExpanded) {
          setState(() => _railW = _collapsed);
        }
      },
      // A WhatsApp list row: avatar, then the name with its age on the right,
      // and under it the last line said with the unread count on the right.
      child: Container(
        color: selected && expanded ? ChatPalette.raised : null,
        padding: EdgeInsets.fromLTRB(
            expanded ? 12.0 + depth * 14 : 10, expanded ? 9 : 5, 10,
            expanded ? 9 : 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            icon,
            if (expanded) ...[
              const SizedBox(width: 13),
              // Two lines: who, and what was last said. A list of bare names
              // cannot tell an active conversation from a dead one.
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (live) ...[
                          Container(
                            width: 8,
                            height: 8,
                            decoration: const BoxDecoration(
                              color: ChatPalette.accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Expanded(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: ChatPalette.text,
                              fontSize: ChatPalette.rowTitleSize,
                              fontWeight: unread > 0
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (age.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text(
                              age,
                              style: TextStyle(
                                fontSize: ChatPalette.rowMetaSize,
                                color: unread > 0
                                    ? ChatPalette.accent
                                    : ChatPalette.secondary,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            sub,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: ChatPalette.rowSubtitleSize,
                              color: ChatPalette.secondary,
                            ),
                          ),
                        ),
                        if (unread > 0)
                          Container(
                            margin: const EdgeInsets.only(left: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            constraints: const BoxConstraints(
                                minWidth: 20, minHeight: 20),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: ChatPalette.accent,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              unread > 99 ? '99+' : '$unread',
                              style: const TextStyle(
                                color: ChatPalette.onAccent,
                                fontSize: ChatPalette.rowMetaSize,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (hasMenu)
                SizedBox(
                  width: 28,
                  child: PopupMenuButton<String>(
                    tooltip: 'More',
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.more_vert,
                        size: 20, color: ChatPalette.secondary),
                    color: ChatPalette.raised,
                    itemBuilder: (_) => _menuItems(),
                    onSelected: (v) => _rowAction(v, id, name),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
    // The menu opens where the finger is.
    final pressable = hasMenu
        ? GestureDetector(
            onLongPressStart: (d) => _menuAt(d.globalPosition, id, name),
            child: tile,
          )
        : tile;
    // Collapsed: hovering tells the full name (desktop); the abbreviated
    // avatar label already carries the gist.
    return expanded ? pressable : Tooltip(message: name, child: pressable);
  }

  // ── Statuses ──────────────────────────────────────────────────────────

  void _postStatus() {
    final text = _statusInput.text.trim();
    if (text.isEmpty) return;
    widget.onPostStatus?.call(text);
    _statusInput.clear();
    FocusScope.of(context).unfocus();
  }

  /// The box to post one's own status, as a pill like the composer's.
  Widget _statusBox() {
    return Container(
      height: 44,
      padding: const EdgeInsets.only(left: 14, right: 4),
      decoration: BoxDecoration(
        color: ChatPalette.raised,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Row(
        children: [
          const Icon(Icons.campaign_outlined,
              size: 20, color: ChatPalette.secondary),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _statusInput,
              // A message is written as a sentence: capital first letter.
              textCapitalization: TextCapitalization.sentences,
              maxLines: 1,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _postStatus(),
              cursorColor: ChatPalette.accent,
              style: TextStyle(
                  color: ChatPalette.text,
                  fontSize: ChatPalette.rowSubtitleSize),
              decoration: InputDecoration(
                hintText: 'Post a status',
                hintStyle: TextStyle(
                    color: ChatPalette.secondary,
                    fontSize: ChatPalette.rowSubtitleSize),
                isDense: true,
                border: InputBorder.none,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Post',
            icon: const Icon(Icons.send, size: 20, color: ChatPalette.accent),
            onPressed: _postStatus,
          ),
        ],
      ),
    );
  }

  /// One person's newest status as a ringed avatar: green while unseen, grey
  /// once opened, the way a messenger marks a story.
  Widget _statusCircle(ColorScheme cs, Map<String, dynamic> st) {
    final call = '${st['call'] ?? ''}';
    final mine = st['mine'] == true;
    final seen = st['seen'] == true || mine;
    return InkWell(
      onTap: () => _openStatus(st),
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 68,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.all(2.5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: seen ? ChatPalette.secondary : ChatPalette.accent,
                  width: seen ? 1.5 : 2.5,
                ),
              ),
              child: _avatar(cs, call, call, false, 48),
            ),
            const SizedBox(height: 4),
            Text(
              mine ? 'You' : call,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: ChatPalette.secondary, fontSize: ChatPalette.rowMetaSize),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusHeader(ColorScheme cs, bool expanded) {
    final list = widget.statuses;
    if (!expanded) {
      // The collapsed rail has room for one circle: it opens the lot.
      final fresh = list.any((s) => s['seen'] != true && s['mine'] != true);
      return Tooltip(
        message: 'Status',
        child: InkWell(
          onTap: () => _openStatusSheet(cs),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: ChatPalette.raised,
                border: Border.all(
                  color: fresh ? ChatPalette.accent : ChatPalette.raised,
                  width: 2.5,
                ),
              ),
              child: const Icon(Icons.campaign_outlined,
                  color: ChatPalette.secondary),
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: _statusBox(),
        ),
        if (list.isNotEmpty)
          SizedBox(
            height: 86,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              children: [for (final st in list) _statusCircle(cs, st)],
            ),
          ),
        const Divider(height: 1, color: ChatPalette.divider),
      ],
    );
  }

  /// The collapsed rail's way in: the box and every status, in a sheet.
  void _openStatusSheet(ColorScheme cs) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ChatPalette.windowBg,
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(sheet).viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: _statusBox(),
              ),
              for (final st in widget.statuses)
                ListTile(
                  leading: _avatar(cs, '${st['call']}', '${st['call']}',
                      false, 40),
                  title: Text(
                      st['mine'] == true ? 'You' : '${st['call']}',
                      style: const TextStyle(color: ChatPalette.text)),
                  subtitle: Text('${st['text'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: ChatPalette.secondary)),
                  onTap: () {
                    Navigator.pop(sheet);
                    _openStatus(st);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// One status, opened: who, when, the words, and a way to answer them in a
  /// private chat.
  void _openStatus(Map<String, dynamic> st) {
    final id = '${st['id'] ?? ''}';
    final call = '${st['call'] ?? ''}';
    final mine = st['mine'] == true;
    if (!mine && st['seen'] != true && id.isNotEmpty) {
      widget.onStatusSeen?.call(id);
    }
    final ts = (st['ts'] as num?)?.toInt() ?? 0;
    final cs = Theme.of(context).colorScheme;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: ChatPalette.raised,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _avatar(cs, call, call, false, 40),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(mine ? 'Your status' : call,
                        style: TextStyle(
                            color: ChatPalette.text,
                            fontSize: ChatPalette.rowTitleSize,
                            fontWeight: FontWeight.w600)),
                  ),
                  Text(_ago(ts * 1000),
                      style: const TextStyle(
                          color: ChatPalette.secondary,
                          fontSize: ChatPalette.rowMetaSize)),
                ],
              ),
              const SizedBox(height: 16),
              SelectableText('${st['text'] ?? ''}',
                  style: TextStyle(
                      color: ChatPalette.text,
                      fontSize: ChatPalette.bodySize + 2,
                      height: 1.35)),
              if (!mine && widget.onDirectMessage != null) ...[
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: ChatPalette.accent,
                      foregroundColor: ChatPalette.onAccent,
                    ),
                    icon: const Icon(Icons.chat_bubble_outline, size: 18),
                    label: const Text('Message'),
                    onPressed: () {
                      Navigator.pop(sheet);
                      widget.onDirectMessage!(call);
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// The head of the list when anything is archived, as in WhatsApp: an icon,
  /// "Archived", and how many conversations it holds (green when one of them
  /// has something unread).
  Widget _archivedTile(bool expanded) {
    final n = widget.archivedCount;
    final hot = widget.archivedUnread > 0;
    final icon = SizedBox(
      width: expanded ? 48 : 44,
      height: expanded ? 30 : 44,
      child: const Icon(Icons.archive_outlined,
          color: ChatPalette.accent, size: 22),
    );
    final tile = InkWell(
      onTap: widget.onArchived,
      child: Padding(
        padding: EdgeInsets.fromLTRB(expanded ? 12 : 10, 8, 10, 8),
        child: Row(
          children: [
            icon,
            if (expanded) ...[
              const SizedBox(width: 13),
              Expanded(
                child: Text(
                  'Archived',
                  style: TextStyle(
                    color: ChatPalette.text,
                    fontSize: ChatPalette.rowTitleSize,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                '${hot ? widget.archivedUnread : n}',
                style: TextStyle(
                  color: hot ? ChatPalette.accent : ChatPalette.secondary,
                  fontSize: ChatPalette.rowMetaSize,
                  fontWeight: hot ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
    return expanded
        ? tile
        : Tooltip(message: 'Archived ($n)', child: tile);
  }

  List<PopupMenuEntry<String>> _menuItems() => [
    if (widget.onArchive != null)
      const PopupMenuItem(
        value: 'archive',
        child: Row(children: [
          Icon(Icons.archive_outlined, size: 20, color: ChatPalette.secondary),
          SizedBox(width: 12),
          Text('Archive chat', style: TextStyle(color: ChatPalette.text)),
        ]),
      ),
    if (widget.onDelete != null)
      const PopupMenuItem(
        value: 'delete',
        child: Row(children: [
          Icon(Icons.delete_outline, size: 20, color: Color(0xFFF15C6D)),
          SizedBox(width: 12),
          Text('Delete chat', style: TextStyle(color: Color(0xFFF15C6D))),
        ]),
      ),
  ];

  Future<void> _menuAt(Offset at, String id, String name) async {
    final v = await showMenu<String>(
      context: context,
      color: ChatPalette.raised,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: _menuItems(),
    );
    if (v != null) _rowAction(v, id, name);
  }

  Future<void> _rowAction(String action, String id, String name) async {
    if (action == 'archive') {
      widget.onArchive?.call(id);
      return;
    }
    if (action != 'delete') return;
    // Deleting cannot be undone, so it is asked once, by name.
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        backgroundColor: ChatPalette.raised,
        title: Text('Delete $name?',
            style: const TextStyle(color: ChatPalette.text)),
        content: const Text(
          'Its messages are removed from this device. This cannot be undone.',
          style: TextStyle(color: ChatPalette.secondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel',
                style: TextStyle(color: ChatPalette.accent)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Delete chat',
                style: TextStyle(color: Color(0xFFF15C6D))),
          ),
        ],
      ),
    );
    if (ok == true) widget.onDelete?.call(id);
  }

  Widget _avatar(
      ColorScheme cs, String id, String name, bool selected, double size) {
    // The label is the NAME, abbreviated — never a bare symbol. Channels are
    // called "#DEV (global)": strip the '#' and the scope suffix, keep up to
    // four letters ("DEV", "NEWS", "NOMA"), so a collapsed rail still reads.
    // A rail of identical '#' circles distinguished only by hash-colour was
    // unusable — nobody knows what to click.
    var label = '';
    for (var i = 0; i < name.length && label.length < 4; i++) {
      final ch = name[i];
      if (ch == ' ' || ch == '(') break; // scope tag: not part of the name
      if (RegExp(r'[A-Za-z0-9]').hasMatch(ch)) label += ch.toUpperCase();
    }
    if (label.isEmpty) label = name.isNotEmpty ? name[0].toUpperCase() : '#';
    final hue = (id.hashCode & 0xff) / 255.0;
    final bg = HSLColor.fromAHSL(1, hue * 360, 0.5, 0.45).toColor();
    final border =
        selected ? Border.all(color: ChatPalette.accent, width: 2.5) : null;
    final initials = Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: border,
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: label.length <= 1
              ? 18
              : label.length == 2
              ? 14
              : label.length == 3
              ? 12
              : 10.5,
          letterSpacing: label.length >= 3 ? -0.3 : 0,
        ),
      ),
    );
    // An open room is a place and keeps its initials. A conversation with one
    // station shows the picture that station announced (XPRS.md 6.3.2), and
    // until it has one the identicon it wears in Status and everywhere else:
    // four letters of a callsign ("X1AR") told two stations apart badly and
    // made the same person look different in each wapp.
    // A closed group is a station too (XPRS.md 10.1) and may announce a
    // picture of its own; until it does, or while it is on its way, the
    // initials stand in for it.
    if (id.startsWith('#X5')) {
      return Container(
        width: size,
        height: size,
        foregroundDecoration:
            BoxDecoration(shape: BoxShape.circle, border: border),
        child: StationAvatar(
            callsign: id.substring(1), size: size, fallback: initials),
      );
    }
    if (id.startsWith('#')) return initials;
    return Container(
      width: size,
      height: size,
      foregroundDecoration:
          BoxDecoration(shape: BoxShape.circle, border: border),
      child: StationAvatar(callsign: id, size: size),
    );
  }

  Widget _chat(ColorScheme cs) {
    final open = widget.openId;
    final room = open == null ? null : widget.store.items[open];
    // Who you are talking to. The store title is the display name.
    //
    // A ROOM gets this header: it names the room and opens the member list.
    // A 1:1 does not: the AppBar already shows the callsign, and a chat
    // conversation is identified by that callsign — there is no address to
    // show and nothing to resolve.
    // Every room and channel id starts with '#', including the scope room
    // (#LOCAL). Anything else is a conversation with one person (a callsign).
    final isDirect = open != null && !open.startsWith('#');
    var name = room?.title ?? '';
    if (name.isEmpty) name = open ?? '';
    return Column(
      children: [
        // room header: who + members toggle (and, on a narrow window where the
        // rail is hidden behind the chat, the way back to it). Rooms only —
        // see isDirect above.
        if (!isDirect)
          Container(
          height: 52,
          padding: const EdgeInsets.only(left: 4, right: 12),
          decoration: const BoxDecoration(
            color: ChatPalette.windowBg,
            border: Border(
              bottom: BorderSide(color: ChatPalette.divider, width: 1),
            ),
          ),
          child: Row(
            children: [
              // No back arrow here: the wapp AppBar's single arrow is the
              // back (the host closes the room on narrow). A second arrow in
              // this header sat directly under it doing something different.
              const SizedBox(width: 8),
              // A closed group shows its face here too (XPRS.md 10.1).
              if (open != null && open.startsWith('#X5')) ...[
                _avatar(cs, open, name, false, 34),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: ChatPalette.text,
                        fontSize: ChatPalette.rowTitleSize,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Members',
                color: ChatPalette.secondary,
                icon: Icon(_membersOpen ? Icons.group : Icons.group_outlined),
                onPressed: () => setState(() => _membersOpen = !_membersOpen),
              ),
            ],
          ),
        ),
        Expanded(
          child: open == null
              ? const ColoredBox(
                  color: ChatPalette.chatBg,
                  child: Center(
                    child: Text(
                      'Pick a room',
                      style: TextStyle(color: ChatPalette.secondary),
                    ),
                  ),
                )
              : GestureDetector(
                  // Swipe left over the chat reveals the member panel — but ONLY
                  // on a wide layout. On a phone, Android's own back gesture is
                  // an inward swipe from the screen edge, which arrives here as
                  // exactly this leftward drag: trying to leave a conversation
                  // opened the member list instead, over and over, with no way
                  // out. The header's group button is the way in on narrow.
                  onHorizontalDragEnd: MediaQuery.of(context).size.width < 640
                      ? null
                      : (d) {
                          if ((d.primaryVelocity ?? 0) < -200) {
                            setState(() => _membersOpen = true);
                          } else if ((d.primaryVelocity ?? 0) > 200) {
                            setState(() => _membersOpen = false);
                          }
                        },
                  child: ChatViewField(
                    key: ValueKey('room-$open'),
                    fieldName: 'rooms_chat',
                    label: '',
                    hint: 'Message',
                    fill: true,
                    safeBottom: true,
                    // The OPEN room, so this is where its tail is read from
                    // the database (the rail above needs none — an unopened
                    // room falls back to its stored preview line).
                    messages: open.isEmpty
                        ? const []
                        : widget.store.messagesOf(open),
                    onSend: (t) => widget.onSend(open, t),
                    // Only a 1:1 has a single recipient to seal to. A group is
                    // several stations behind one name (6.3), so there is no
                    // key to seal a group message with and the switch is not
                    // offered there.
                    onTogglePrivacy: isDirect ? widget.onTogglePrivacy : null,
                    privacyOn: widget.privacyOn,
                    onSenderTap: widget.onSenderTap,
                    onReveal: widget.onReveal,
                    onHide: widget.onHide == null
                        ? null
                        : (m) =>
                              widget.onHide!(open, (m['key'] ?? '').toString()),
                    onBlock: widget.onBlock == null
                        ? null
                        : (m) => widget.onBlock!((m['from'] ?? '').toString()),
                    onDirectMessage: widget.onDirectMessage,
                    onAttach: widget.onAttach,
                  ),
                ),
        ),
      ],
    );
  }

  Widget _members(ColorScheme cs) {
    return Column(
      children: [
        Container(
          height: 48,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: ChatPalette.divider, width: 1),
            ),
          ),
          child: Text(
            'Members',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        Expanded(
          child: PeopleViewField(
            fieldName: 'room_members',
            sections: widget.memberSections,
            onTap: widget.onMemberTap,
            onAction: (action, id) => widget.onMemberTap(id),
          ),
        ),
      ],
    );
  }
}

/// [rows] ordered most recent first, with each row that names a `parent`
/// on the list drawn under it rather than among the roots: a folder inside
/// a group (XPRS.md 10.2) belongs beside its group, not wherever its last
/// message put it. Siblings are ordered the same way the roots are, and a
/// branch moves up with its busiest row. A row whose parent is not on the
/// list is a root. Pure, so the order is a test rather than a screenshot.
List<Map<String, dynamic>> roomsTreeByRank(
    List<Map<String, dynamic>> rows, int Function(Map<String, dynamic>) rank) {
  final idx = {for (var i = 0; i < rows.length; i++) '${rows[i]['id']}': i};
  final kids = <String, List<Map<String, dynamic>>>{};
  final roots = <Map<String, dynamic>>[];
  for (final r in rows) {
    final up = '${r['parent'] ?? ''}';
    if (up.isNotEmpty && up != '${r['id']}' && idx.containsKey(up)) {
      kids.putIfAbsent(up, () => []).add(r);
    } else {
      roots.add(r);
    }
  }
  final best = <String, int>{};
  int branch(Map<String, dynamic> r, Set<String> seen) {
    final id = '${r['id']}';
    final hit = best[id];
    if (hit != null) return hit;
    var b = rank(r);
    if (seen.add(id)) {
      for (final k in kids[id] ?? const <Map<String, dynamic>>[]) {
        final kb = branch(k, seen);
        if (kb > b) b = kb;
      }
    }
    return best[id] = b;
  }

  int order(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ra = branch(a, {}), rb = branch(b, {});
    if (ra != rb) return rb.compareTo(ra);
    // Never-touched rows keep their given order (the room tree's shape).
    return (idx['${a['id']}'] ?? 0).compareTo(idx['${b['id']}'] ?? 0);
  }

  final out = <Map<String, dynamic>>[];
  final placed = <String>{};
  void place(Map<String, dynamic> r) {
    if (!placed.add('${r['id']}')) return;
    out.add(r);
    for (final k in [...?kids['${r['id']}']]..sort(order)) {
      place(k);
    }
  }

  for (final r in roots..sort(order)) {
    place(r);
  }
  // A cycle of parents has no root to hang from; draw it flat.
  for (final r in rows) {
    place(r);
  }
  return out;
}
