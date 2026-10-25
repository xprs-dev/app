import 'dart:async';

import 'package:flutter/material.dart';
import '../../../services/i18n/core_i18n.dart';

/// `$type:"members"`: a full-size panel to look through and manage the people
/// of one thing (a group, a channel, a project), reusable by any wapp.
///
/// The widget holds no list of its own. A group can have hundreds of members,
/// so the wapp keeps the roster and answers one page at a time: this widget
/// asks for a page (query, filter, offset) and draws what comes back, with the
/// list built lazily and the next page requested as the end scrolls into view.
/// Search is sent to the wapp (debounced) rather than filtered here, because a
/// filter over the rows held would miss everyone on a page not yet fetched.
///
/// Data in, `ui.members.set`, one JSON object:
///   field     the field name
///   offset    0 replaces the rows; otherwise appends when it equals what is held
///   rows      [{id,title,subtitle,icon,tag}], this page only
///   total     how many match the current query and filter
///   title, subtitle, icon   the header (kept when a page leaves them out)
///   actions   [{id,label,icon,primary}], buttons under the header
///   filters   [{id,label,count}], chips; id "" is "All"
///   reset     true clears the query and the filter (a fresh open)
///
/// Commands out: `<field>_page` (with `<field>_query`, `<field>_filter`,
/// `<field>_offset`), `<field>_tap` (with `<field>_id`) and `<field>_action`
/// (with `<field>_id` naming the action).
class MembersPanelField extends StatefulWidget {
  final String fieldName;
  final Map<String, dynamic> data;
  final String query;
  final String filter;
  final void Function(String query) onSearch;
  final void Function(String filter) onFilter;
  final void Function(int offset) onMore;
  final void Function(String id) onTap;
  final void Function(String id) onAction;
  final String? emptyText;

  const MembersPanelField({
    super.key,
    required this.fieldName,
    required this.data,
    required this.query,
    required this.filter,
    required this.onSearch,
    required this.onFilter,
    required this.onMore,
    required this.onTap,
    required this.onAction,
    this.emptyText,
  });

  @override
  State<MembersPanelField> createState() => _MembersPanelFieldState();
}

class _MembersPanelFieldState extends State<MembersPanelField> {
  final _search = TextEditingController();
  Timer? _debounce;
  // The offset a page was last asked for, so a rebuild near the end of the
  // list does not ask again before the answer lands.
  int _askedAt = -1;

  @override
  void initState() {
    super.initState();
    _search.text = widget.query;
  }

  @override
  void didUpdateWidget(MembersPanelField old) {
    super.didUpdateWidget(old);
    // A fresh open (the wapp reset the query) empties the box; typing never
    // lands here with a different value, it is the box that set it.
    if (widget.query != old.query && widget.query != _search.text) {
      _search.text = widget.query;
    }
    if (_rows.length != _rowsOf(old.data).length) _askedAt = -1;
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  static List<Map<String, dynamic>> _rowsOf(Map<String, dynamic> d) {
    final r = d['rows'];
    return r is List
        ? r.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList()
        : const <Map<String, dynamic>>[];
  }

  List<Map<String, dynamic>> get _rows => _rowsOf(widget.data);

  List<Map<String, dynamic>> _listOf(String key) {
    final r = widget.data[key];
    return r is List
        ? r.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList()
        : const <Map<String, dynamic>>[];
  }

  void _typed(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      _askedAt = -1;
      widget.onSearch(q.trim());
    });
  }

  IconData _icon(String? name) => switch (name) {
        'person_add' => Icons.person_add_alt_1,
        'create_new_folder' => Icons.create_new_folder_outlined,
        'image' => Icons.image_outlined,
        'group' => Icons.group_outlined,
        'person' => Icons.person_outline,
        'admin_panel_settings' => Icons.admin_panel_settings_outlined,
        'block' => Icons.block,
        'edit' => Icons.edit_outlined,
        'share' => Icons.share_outlined,
        'link' => Icons.link,
        _ => Icons.label_outline,
      };

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final rows = _rows;
    final total = (widget.data['total'] as num?)?.toInt() ?? rows.length;
    final title = '${widget.data['title'] ?? ''}';
    final subtitle = '${widget.data['subtitle'] ?? ''}';
    final actions = _listOf('actions');
    final filters = _listOf('filters');
    final more = rows.length < total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: tt.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                if (subtitle.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(subtitle,
                        style: tt.bodyMedium
                            ?.copyWith(color: cs.onSurfaceVariant)),
                  ),
              ],
            ),
          ),
        if (actions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final a in actions)
                  (a['primary'] == true
                          ? FilledButton.icon(
                              onPressed: () => widget.onAction('${a['id']}'),
                              icon: Icon(_icon(a['icon'] as String?), size: 18),
                              label: Text('${a['label'] ?? a['id']}'),
                            )
                          : FilledButton.tonalIcon(
                              onPressed: () => widget.onAction('${a['id']}'),
                              icon: Icon(_icon(a['icon'] as String?), size: 18),
                              label: Text('${a['label'] ?? a['id']}'),
                            )),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: _search,
            onChanged: _typed,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: tr('common.search'),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _search.clear();
                        _typed('');
                        setState(() {});
                      },
                    ),
              filled: true,
              fillColor: cs.surfaceContainerHighest,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(28),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (filters.length > 1)
          SizedBox(
            height: 48,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final f in filters)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Center(
                      child: ChoiceChip(
                        label: Text(
                          f['count'] == null
                              ? '${f['label']}'
                              : '${f['label']} ${f['count']}',
                        ),
                        selected: '${f['id'] ?? ''}' == widget.filter,
                        onSelected: (_) {
                          _askedAt = -1;
                          widget.onFilter('${f['id'] ?? ''}');
                        },
                      ),
                    ),
                  ),
              ],
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      widget.query.isEmpty
                          ? (widget.emptyText ?? tr('geoui.members.empty'))
                          : tr('geoui.members.no_match', {'query': widget.query}),
                      textAlign: TextAlign.center,
                      style: tt.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ),
                )
              : ListView.builder(
                  // Built as scrolled to: hundreds of rows cost the rows on
                  // screen, not the roster.
                  itemCount: rows.length + (more ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i >= rows.length) {
                      // The end came into view: ask for the next page, once.
                      if (_askedAt != rows.length) {
                        _askedAt = rows.length;
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) widget.onMore(rows.length);
                        });
                      }
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }
                    final r = rows[i];
                    final sub = '${r['subtitle'] ?? ''}';
                    final tag = '${r['tag'] ?? ''}';
                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: cs.surfaceContainerHighest,
                        foregroundColor: cs.onSurfaceVariant,
                        child: Icon(_icon(r['icon'] as String? ?? 'person')),
                      ),
                      title: Text('${r['title'] ?? r['id']}',
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: sub.isEmpty
                          ? null
                          : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: tag.isEmpty
                          ? null
                          : Chip(
                              label: Text(tag),
                              visualDensity: VisualDensity.compact,
                            ),
                      onTap: () => widget.onTap('${r['id']}'),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
