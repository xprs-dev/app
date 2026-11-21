/*
 * The other identities a person states of themselves (XPRS.md 6.3.3), on the
 * profile page: one row per kind, with what goes in `data:` and how far its
 * owner lets it be told. The page keeps the list and saves it with the
 * profile; the core airs it (XprsPublisher.publishIdentities).
 */
import 'package:flutter/material.dart';

import 'iwi_profile.dart';
import '../services/i18n/core_i18n.dart';
import '../services/people/xprs_people.dart';

/// The scopes offered. Country codes are a scope too and are kept when a
/// profile has them; the form offers the three everybody understands.
const List<String> _scopes = ['local', 'regional', 'global'];

class OtherIdentitiesEditor extends StatefulWidget {
  const OtherIdentitiesEditor(
      {super.key, required this.identities, required this.onChanged});

  final List<StatedIdentities> identities;
  final ValueChanged<List<StatedIdentities>> onChanged;

  /// [text] as the values of one kind: split on commas, spaces and new
  /// lines (a value has neither on the wire), each normalised for its kind,
  /// the ones that cannot be of that kind left out and returned in `bad`.
  static ({List<String> good, List<String> bad}) parse(
      String type, String text) {
    final good = <String>[], bad = <String>[];
    for (final raw in text.split(RegExp(r'[\s,;]+'))) {
      if (raw.isEmpty) continue;
      final v = XprsIdType.normalise(type, raw);
      if (v.isEmpty) {
        bad.add(raw);
      } else if (!good.contains(v)) {
        good.add(v);
      }
    }
    return (good: good, bad: bad);
  }

  @override
  State<OtherIdentitiesEditor> createState() => _OtherIdentitiesEditorState();
}

class _OtherIdentitiesEditorState extends State<OtherIdentitiesEditor> {
  final _value = TextEditingController();
  String _type = XprsIdType.statable.first;
  String _scope = XprsIdType.defaultScope(XprsIdType.statable.first);
  String? _error;

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  static String typeLabel(String type) {
    final key = 'profile.ids.type.$type';
    final t = tr(key);
    return t == key ? type : t;
  }

  static String scopeLabel(String scope) {
    final s = scope.isEmpty ? 'global' : scope;
    final key = 'profile.ids.scope.$s';
    final t = tr(key);
    return t == key ? s : t;
  }

  void _add() {
    final parsed = OtherIdentitiesEditor.parse(_type, _value.text);
    if (parsed.good.isEmpty) {
      setState(() => _error = tr('profile.ids.invalid',
          {'type': typeLabel(_type)}));
      return;
    }
    final list = List<StatedIdentities>.of(widget.identities);
    final at = list.indexWhere((i) => i.type == _type);
    final merged = <String>[
      if (at >= 0) ...list[at].values,
      for (final v in parsed.good)
        if (at < 0 || !list[at].values.contains(v)) v,
    ];
    final entry = StatedIdentities(_type, merged, scope: _scope);
    if (at >= 0) {
      list[at] = entry;
    } else {
      list.add(entry);
    }
    widget.onChanged(list);
    setState(() {
      _value.clear();
      _error = parsed.bad.isEmpty
          ? null
          : tr('profile.ids.skipped', {'what': parsed.bad.join(', ')});
    });
  }

  void _removeValue(StatedIdentities of, String value) {
    final list = List<StatedIdentities>.of(widget.identities);
    final at = list.indexWhere((i) => i.type == of.type);
    if (at < 0) return;
    final left = [for (final v in of.values) if (v != value) v];
    if (left.isEmpty) {
      list.removeAt(at);
    } else {
      list[at] = StatedIdentities(of.type, left, scope: of.scope);
    }
    widget.onChanged(list);
  }

  void _rescope(StatedIdentities of, String scope) {
    final list = List<StatedIdentities>.of(widget.identities);
    final at = list.indexWhere((i) => i.type == of.type);
    if (at < 0) return;
    list[at] = StatedIdentities(of.type, of.values, scope: scope);
    widget.onChanged(list);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(tr('profile.ids.title'), style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(tr('profile.ids.help'), style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        for (final set in widget.identities)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(typeLabel(set.type),
                          style: theme.textTheme.labelLarge),
                    ),
                    DropdownButton<String>(
                      value: _scopes.contains(set.scope.isEmpty
                              ? 'global'
                              : set.scope)
                          ? (set.scope.isEmpty ? 'global' : set.scope)
                          : null,
                      hint: Text(set.scope),
                      isDense: true,
                      items: [
                        for (final s in _scopes)
                          DropdownMenuItem(
                              value: s, child: Text(scopeLabel(s))),
                      ],
                      onChanged: (s) =>
                          s == null ? null : _rescope(set, s),
                    ),
                  ],
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  children: [
                    for (final v in set.values)
                      InputChip(
                        label: Text(v,
                            style: const TextStyle(fontFamily: 'monospace')),
                        onDeleted: () => _removeValue(set, v),
                        deleteButtonTooltipMessage:
                            tr('profile.ids.remove', {'what': v}),
                      ),
                  ],
                ),
              ],
            ),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButton<String>(
              value: _type,
              items: [
                for (final t in XprsIdType.statable)
                  DropdownMenuItem(value: t, child: Text(typeLabel(t))),
              ],
              onChanged: (t) => setState(() {
                _type = t ?? _type;
                final held = widget.identities
                    .where((i) => i.type == _type)
                    .firstOrNull;
                _scope = held == null
                    ? XprsIdType.defaultScope(_type)
                    : (held.scope.isEmpty ? 'global' : held.scope);
                _error = null;
              }),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _value,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  isDense: true,
                  labelText: typeLabel(_type),
                  errorText: _error,
                  helperText: tr('profile.ids.scope.help.'
                      '${_scopes.contains(_scope) ? _scope : 'global'}'),
                  helperMaxLines: 3,
                ),
                onSubmitted: (_) => _add(),
              ),
            ),
          ],
        ),
        Row(
          children: [
            Text(tr('profile.ids.scope'), style: theme.textTheme.bodySmall),
            const SizedBox(width: 8),
            DropdownButton<String>(
              value: _scopes.contains(_scope) ? _scope : 'global',
              isDense: true,
              items: [
                for (final s in _scopes)
                  DropdownMenuItem(value: s, child: Text(scopeLabel(s))),
              ],
              onChanged: (s) => setState(() => _scope = s ?? _scope),
            ),
            const Spacer(),
            FilledButton.tonal(onPressed: _add, child: Text(tr('common.add'))),
          ],
        ),
      ],
    );
  }
}
