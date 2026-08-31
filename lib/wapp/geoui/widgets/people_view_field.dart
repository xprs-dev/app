/* XPRS · GeoUI people list ($type:"people")
 *
 * PeopleViewField — a social-network style people list: segmented sections
 * (e.g. Following | Followers), one row per person with an avatar, title,
 * subtitle, tag chips and a trailing action button (Follow / Following).
 * Completely data-driven: the wapp pushes the content via `ui.people.set`
 * and receives generic field-derived commands back:
 *   <field>_tap     (row tapped;            <field>_id = row id)
 *   <field>_<name>  (trailing button tapped; <field>_id = row id)
 * The host knows nothing about what the rows or actions mean.
 */

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../util/media_ref.dart';
import '../../shared_media_fetch.dart' show resolveSharedMedia;
import '../geoui_renderer.dart' show geoUiResolveIcon;
import 'generated_avatar.dart';
import 'media_view.dart' show sharedMediaArchive;

class PeopleViewField extends StatefulWidget {
  final String fieldName;

  /// Sections as pushed by the wapp: [{title, items:[{id, title, subtitle,
  /// tags:[..], action, actionLabel, actionStyle}]}].
  final List<Map<String, dynamic>> sections;

  /// Row tapped → host forwards `<field>_tap` with `<field>_id`.
  final void Function(String id) onTap;

  /// Trailing button tapped → host forwards `<field>_<action>` with
  /// `<field>_id`.
  final void Function(String action, String id) onAction;

  /// Message shown when the active section has no rows.
  final String? emptyText;

  const PeopleViewField({
    super.key,
    required this.fieldName,
    required this.sections,
    required this.onTap,
    required this.onAction,
    this.emptyText,
  });

  @override
  State<PeopleViewField> createState() => _PeopleViewFieldState();
}

class _PeopleViewFieldState extends State<PeopleViewField> {
  int _section = 0;

  /// The user tapped this filter themselves, so leave it alone even when it
  /// is empty — "Rooms: none" is an answer somebody asked for. Cleared the
  /// moment the content changes underneath them (a new search query), because
  /// then the empty filter is no longer an answer, just a stale choice.
  bool _pinned = false;

  int _count(int i) => ((widget.sections[i]['items'] as List?) ?? const []).length;

  /// Fingerprint of what is on offer. Only the shape matters — which filters
  /// exist and how many rows each holds — because that is exactly what makes
  /// a previous choice stale.
  String _shape(List<Map<String, dynamic>> s) => [
        for (final x in s)
          '${x['title']}:${((x['items'] as List?) ?? const []).length}',
      ].join('|');

  @override
  void didUpdateWidget(covariant PeopleViewField old) {
    super.didUpdateWidget(old);
    if (_shape(old.sections) != _shape(widget.sections)) _pinned = false;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sections = widget.sections;
    if (_section >= sections.length) _section = 0;
    // Never open on an empty filter while another one has results. Searching
    // for something that exists and being shown "nothing here" — because the
    // first filter happened to be the empty one — reads as "not found", and
    // the answer was one tap away the whole time.
    if (!_pinned && sections.isNotEmpty && _count(_section) == 0) {
      for (var i = 0; i < sections.length; i++) {
        if (_count(i) > 0) {
          _section = i;
          break;
        }
      }
    }
    final items = sections.isEmpty
        ? const <Map<String, dynamic>>[]
        : ((sections[_section]['items'] as List?) ?? const [])
              .whereType<Map>()
              .map((m) => m.cast<String, dynamic>())
              .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Filter chips, not tabs. Tabs divided the width equally and made
        // every label as wide as the widest one could be: three of them turned
        // "Channels and conversations (3)" into two wrapped lines and a strip
        // three times taller than the rows it filters. A chip is as wide as
        // its word, the strip scrolls when the words do not fit, and a filter
        // with nothing behind it is dimmed rather than shouting "(0)".
        if (sections.length > 1)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            child: Row(
              children: [
                for (var i = 0; i < sections.length; i++) ...[
                  if (i > 0) const SizedBox(width: 8),
                  _sectionChip(cs, sections[i], i),
                ],
              ],
            ),
          ),
        if (sections.length > 1) const Divider(height: 1),
        Expanded(
          child: items.isEmpty
              ? _empty(cs)
              : ListView.separated(
                  itemCount: items.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    indent: 72,
                    color: cs.outlineVariant.withAlpha(50),
                  ),
                  itemBuilder: (context, i) => _row(cs, items[i]),
                ),
        ),
      ],
    );
  }

  Widget _sectionChip(ColorScheme cs, Map<String, dynamic> s, int idx) {
    final sel = _section == idx;
    final title = (s['title'] ?? '').toString();
    final count = ((s['items'] as List?) ?? const []).length;
    final iconName = (s['icon'] ?? '').toString();
    final icon = iconName.isEmpty ? null : geoUiResolveIcon(iconName);
    // A filter with nothing behind it stays tappable — "show me the rooms" is
    // a fair question even when the answer is none — but it recedes, so the
    // eye lands on the ones that have something.
    final fg = sel
        ? cs.onPrimaryContainer
        : (count == 0 ? cs.onSurfaceVariant.withAlpha(110) : cs.onSurfaceVariant);

    final chip = Container(
      padding: EdgeInsets.symmetric(horizontal: icon != null ? 12 : 14, vertical: 7),
      decoration: BoxDecoration(
        color: sel ? cs.primaryContainer : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: sel ? cs.primary.withAlpha(120) : cs.outlineVariant.withAlpha(70),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A section may name an ICON instead of a word — then the icon IS
          // the label. Either way the count rides alongside it, and only when
          // there is one: "People 0" is three characters of nothing, and the
          // dimmed chip has already said it.
          if (icon != null)
            Icon(icon, size: 17, color: fg)
          else
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                color: fg,
              ),
            ),
          if (count > 0) ...[
            const SizedBox(width: 6),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: sel ? cs.onPrimaryContainer : cs.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => setState(() {
        _section = idx;
        _pinned = true;
      }),
      // The word survives as the tooltip when the chip is an icon, so nothing
      // is lost for anyone who wants it.
      child: icon != null ? Tooltip(message: title, child: chip) : chip,
    );
  }

  Widget _empty(ColorScheme cs) {
    return Center(
      child: Text(
        (widget.emptyText?.isNotEmpty ?? false)
            ? widget.emptyText!
            : 'Nobody here yet.',
        textAlign: TextAlign.center,
        style: TextStyle(color: cs.onSurfaceVariant),
      ),
    );
  }

  Widget _row(ColorScheme cs, Map<String, dynamic> it) {
    final id = (it['id'] ?? '').toString();
    final title = (it['title'] ?? id).toString();
    final subtitle = (it['subtitle'] ?? '').toString();
    final tags = ((it['tags'] as List?) ?? const [])
        .map((t) => t.toString())
        .where((t) => t.isNotEmpty)
        .toList();
    final action = (it['action'] ?? '').toString();
    final actionLabel = (it['actionLabel'] ?? '').toString();
    final avatar = (it['avatar'] ?? '').toString();
    // "filled" reads as the suggestion (Follow), "outlined" as the current
    // state (Following) — matching the familiar social-app pattern.
    final filled = (it['actionStyle'] ?? 'outlined').toString() == 'filled';
    // Optional per-row overflow ("...") menu: [{label, value}]. Selecting an
    // entry fires onAction(value, id) — same path as the trailing button.
    final menu = ((it['menu'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .where((m) => (m['value'] ?? '').toString().isNotEmpty)
        .toList();
    // Optional row of small trailing icon buttons: [{icon, action, tip}].
    // Each fires onAction(action, id) — for compact per-row controls like an
    // edit pencil and a remove (−) button.
    final buttons = ((it['buttons'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .where((m) => (m['action'] ?? '').toString().isNotEmpty)
        .toList();

    // A row can name an ICON instead of taking a generated avatar. The avatar is
    // right when the row is a person (it makes strangers distinguishable at a
    // glance); it is nonsense when the row is a folder or a file, where a random
    // coloured sigil says nothing and the type says everything.
    final iconName = (it['icon'] ?? '').toString();
    // `dim: true` — the row is real but no longer current (e.g. a device last
    // heard an hour ago). Greyed rather than hidden: "who was here" is the
    // question a presence list answers second, right after "who is here now".
    final dim = it['dim'] == true;

    return Opacity(
      opacity: dim ? 0.45 : 1,
      child: InkWell(
        onTap: () => widget.onTap(id),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (avatar.startsWith('file:'))
                // A content-addressed media token (e.g. a torrent's favicon-style
                // icon): render from the local archive, fetching if we do not hold
                // it yet. Falls back to the generated avatar until it lands.
                _TokenAvatar(token: avatar, seed: id, size: 44)
              else if (avatar.isNotEmpty)
                ClipOval(
                  child: Image.network(
                    avatar,
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) =>
                        GeneratedAvatar(seed: id, size: 44),
                  ),
                )
              else if (iconName.isEmpty)
                GeneratedAvatar(seed: id, size: 44)
              else
                SizedBox(
                  width: 44,
                  height: 44,
                  child: Icon(
                    geoUiResolveIcon(iconName),
                    size: 30,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    if (subtitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: cs.onSurfaceVariant,
                            fontSize: 12.5,
                          ),
                        ),
                      ),
                    if (tags.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 5),
                        child: Wrap(
                          spacing: 5,
                          runSpacing: 5,
                          children: [
                            for (final t in tags)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: cs.primaryContainer.withAlpha(110),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  t,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: cs.onPrimaryContainer,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (action.isNotEmpty && actionLabel.isNotEmpty) ...[
                const SizedBox(width: 8),
                filled
                    ? FilledButton(
                        style: FilledButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        onPressed: () => widget.onAction(action, id),
                        child: Text(actionLabel),
                      )
                    : OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                        ),
                        onPressed: () => widget.onAction(action, id),
                        child: Text(actionLabel),
                      ),
              ],
              for (final b in buttons)
                IconButton(
                  icon: Icon(_rowIcon((b['icon'] ?? '').toString()), size: 20),
                  tooltip: (b['tip'] ?? '').toString(),
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      widget.onAction((b['action']).toString(), id),
                ),
              if (menu.isNotEmpty)
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert),
                  tooltip: 'More',
                  onSelected: (v) => widget.onAction(v, id),
                  itemBuilder: (_) => [
                    for (final m in menu)
                      PopupMenuItem<String>(
                        value: (m['value'] ?? '').toString(),
                        child: Text(
                          (m['label'] ?? m['value'] ?? '').toString(),
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _rowIcon(String name) {
    switch (name) {
      case 'edit':
        return Icons.edit_outlined;
      case 'delete':
      case 'remove':
        return Icons.remove_circle_outline;
      case 'add':
        return Icons.add_circle_outline;
      case 'star':
      case 'default':
        return Icons.star_outline;
      case 'lock':
      case 'access':
        return Icons.lock_outline;
      case 'settings':
        return Icons.settings_outlined;
      case 'mail':
      case 'message':
        return Icons.mail_outline;
      default:
        return Icons.more_horiz;
    }
  }
}

/// A circular avatar rendered from a content-addressed media token (`file:<sha>.
/// <ext>`) — a torrent's favicon-style icon. Reads the bytes from the local
/// archive, kicks off a fetch when we do not hold them yet, and shows the
/// generated avatar until they land (so the row is never blank).
class _TokenAvatar extends StatefulWidget {
  final String token;
  final String seed;
  final double size;
  const _TokenAvatar({required this.token, required this.seed, this.size = 44});

  @override
  State<_TokenAvatar> createState() => _TokenAvatarState();
}

class _TokenAvatarState extends State<_TokenAvatar> {
  Uint8List? _bytes;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant _TokenAvatar old) {
    super.didUpdateWidget(old);
    if (old.token != widget.token) {
      _bytes = null;
      _poll?.cancel();
      _poll = null;
      _load();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _load() {
    final ref = MediaRef.parse(widget.token);
    if (ref == null) return;
    final a = sharedMediaArchive();
    if (a == null) return;
    final b = a.get(ref.sha256);
    if (b != null && b.isNotEmpty) {
      setState(() => _bytes = b);
      return;
    }
    // Not held yet — pull it (icons are tiny) and poll briefly for arrival.
    // ignore: discarded_futures
    resolveSharedMedia(ref.sha256, ref.ext);
    _poll = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      final bb = sharedMediaArchive()?.get(ref.sha256);
      if (bb != null && bb.isNotEmpty) {
        t.cancel();
        setState(() => _bytes = bb);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_bytes == null) {
      return GeneratedAvatar(seed: widget.seed, size: widget.size);
    }
    return ClipOval(
      child: Image.memory(
        _bytes!,
        width: widget.size,
        height: widget.size,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        // An avatar is drawn at `size`; 3x covers the densest phone screen.
        cacheWidth: (widget.size * 3).toInt(),
        errorBuilder: (_, __, ___) =>
            GeneratedAvatar(seed: widget.seed, size: widget.size),
      ),
    );
  }
}
