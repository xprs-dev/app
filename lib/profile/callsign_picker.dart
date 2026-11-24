/*
 * CallsignPickerPage — the one screen for choosing a callsign, whoever it is
 * for: a person (X1, the welcome page), a station (X3, a board flashed by the
 * Firmwares wapp) or a group (X5, a new group in Chat).
 *
 * A callsign is its kind's two characters and the first characters of a key
 * (XPRS.md 3), so choosing one means generating keys until one starts the way
 * the person likes. The screen is the same for every kind: type a few
 * letters, watch it search, tap the one you want. What differs is WHERE the
 * keys are made, and that is a [CallsignKeySource]: [IsolateCallsignSource]
 * searches on a worker isolate (callsign_search_io.dart; docs/performance.md
 * 8.1) and hands the chosen key back. Who keeps it is the caller's business:
 * a person's profile, a station the Firmwares wapp hands it to sealed, or the
 * core's group-key pool (XprsGroupKeys.offer, 26.1: a wapp never holds a
 * group's key).
 *
 * Returns the chosen [PickedCallsign] via Navigator.pop, or null when the
 * person backs out. Nothing is written anywhere here.
 */

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:reticulum/reticulum.dart' show NostrCrypto;

import '../services/i18n/core_i18n.dart';
import 'callsign_key_source.dart';

export 'callsign_key_source.dart';
export 'callsign_search.dart';

/// The only characters a callsign can ever contain.
///
/// A callsign is `X1` + two to five characters of the npub, and an npub is
/// bech32 — whose alphabet is `qpzry9x8gf2tvdw0s3jn54khce6mua7l`. So **B, I, O
/// and 1 do not exist in any callsign**, and neither does any other character
/// outside this set.
///
/// This is not a detail: without it the search box happily accepts "AB" and then
/// grinds forever on a pattern that cannot occur. (It did exactly that — 17,000
/// keys, zero matches, no explanation.) The field is therefore restricted to
/// characters that can actually be found.
const String kCallsignAlphabet = 'QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7L';

/// How many characters of the key a callsign shows, and the default (spec
/// section 3). Four is what every callsign in the field is today.
const int kMinCallsignLength = NostrCrypto.kMinCallsignLength;
const int kMaxCallsignLength = NostrCrypto.kMaxCallsignLength;
const int kDefaultCallsignLength = NostrCrypto.kDefaultCallsignLength;

/// What a given length actually costs the holder, said plainly.
///
/// The numbers are `32^n`: how many callsigns exist at that length, after how
/// many users two people are more likely than not to share one, and how many
/// keypairs someone must grind to wear yours. A short callsign is a weak one
/// and the screen has to say so rather than let the user find out later.
class CallsignLengthFacts {
  final int length;
  final int space;
  final int collideAfter;

  const CallsignLengthFacts(this.length, this.space, this.collideAfter);

  static const List<CallsignLengthFacts> all = [
    CallsignLengthFacts(2, 1024, 40),
    CallsignLengthFacts(3, 32768, 226),
    CallsignLengthFacts(4, 1048576, 1283),
    CallsignLengthFacts(5, 33554432, 7259),
  ];

  static CallsignLengthFacts of(int length) =>
      all.firstWhere((f) => f.length == length,
          orElse: () => all[kDefaultCallsignLength - kMinCallsignLength]);

  /// How long grinding a matching key takes, in words rather than keypairs.
  String get forgeEffort => switch (length) {
        2 => tr('onboarding.vanity.forge.seconds_under'),
        3 => tr('onboarding.vanity.forge.seconds_few'),
        4 => tr('onboarding.vanity.forge.minutes_few'),
        _ => tr('onboarding.vanity.forge.hours'),
      };

  bool get isWeak => length < kDefaultCallsignLength;

  /// 1048576 -> "1,048,576". Local rather than a dependency on intl for one
  /// string on one screen.
  static String grouped(int v) {
    final s = v.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
      b.write(s[i]);
    }
    return b.toString();
  }
}

class CallsignPickerPage extends StatefulWidget {
  /// Where the keys come from, and so what kind of callsign this is.
  final CallsignKeySource source;

  /// The callsign in play now, so the person knows what they would replace.
  /// Empty when there is none yet (a board not flashed).
  final String currentCallsign;

  /// A length the caller cannot change: a station derives its callsign with
  /// its firmware's length and a group with the core's, so offering another
  /// would find keys that come out differently. Null shows the length picker.
  final int? fixedLength;

  const CallsignPickerPage({
    super.key,
    required this.source,
    this.currentCallsign = '',
    this.fixedLength,
  });

  @override
  State<CallsignPickerPage> createState() => _CallsignPickerPageState();
}

class _CallsignPickerPageState extends State<CallsignPickerPage> {
  final TextEditingController _pattern = TextEditingController();

  /// How many characters of the key the callsign will show.
  late int _length = widget.fixedLength ?? kDefaultCallsignLength;

  bool _running = false;
  int _tried = 0;
  String _gaveUp = '';
  Duration _elapsed = Duration.zero;
  Stopwatch? _watch;
  final List<PickedCallsign> _matches = [];

  String get _prefix => widget.source.prefix;

  @override
  void dispose() {
    _stop();
    _pattern.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final pattern = _pattern.text.trim().toUpperCase();
    if (pattern.isEmpty || pattern.length > _length) return;
    // Belt and braces: the field already filters, but a pattern containing a
    // character no callsign can hold would search until the battery died.
    if (pattern.split('').any((c) => !kCallsignAlphabet.contains(c))) return;
    setState(() {
      _running = true;
      _tried = 0;
      _gaveUp = '';
      _elapsed = Duration.zero;
      _matches.clear();
    });
    // No timer: every source reports at least twice a second while it
    // searches, and each report moves the clock (CallsignKeySource.start).
    _watch = Stopwatch()..start();
    await widget.source.start(pattern, _length, (tried, found) {
      if (!mounted) return;
      setState(() {
        _tried += tried;
        _elapsed = _watch?.elapsed ?? _elapsed;
        for (final m in found) {
          // New matches go below, so the row under a finger never moves.
          if (_matches.length >= 50) break;
          if (_matches.any((p) => p.callsign == m.callsign)) continue;
          _matches.add(m);
        }
      });
    }, (why) {
      if (!mounted) return;
      _stop();
      setState(() => _gaveUp = why);
    });
  }

  /// Changing the length invalidates every match already found (they are the
  /// wrong shape now) and any pattern longer than the new callsign.
  void _setLength(int n) {
    if (n == _length || _running) return;
    setState(() {
      _length = n;
      _matches.clear();
      _tried = 0;
      _elapsed = Duration.zero;
      if (_pattern.text.length > n) {
        _pattern.text = _pattern.text.substring(0, n);
      }
    });
  }

  void _stop() {
    widget.source.stop();
    _running = false;
    _watch?.stop();
    if (mounted) setState(() {});
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// Hand the choice back. Stop the search first: it is a core at 100% and
  /// nobody is watching it any more.
  void _use(PickedCallsign p) {
    _stop();
    Navigator.of(context).pop(p);
  }

  /// How long the callsign is, and what that choice costs.
  ///
  /// Shorter is genuinely weaker and the screen says so where the choice is
  /// made, not in a footnote: a two-character callsign collides after about
  /// forty users and can be forged in a thousand tries. The number is not
  /// hidden behind "advanced".
  Widget _lengthPicker(ThemeData theme, ColorScheme cs) {
    final facts = CallsignLengthFacts.of(_length);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(tr('onboarding.vanity.length'),
            style: theme.textTheme.labelLarge
                ?.copyWith(color: cs.onSurfaceVariant)),
        const SizedBox(height: 8),
        SegmentedButton<int>(
          segments: [
            for (var i = kMinCallsignLength; i <= kMaxCallsignLength; i++)
              ButtonSegment<int>(
                value: i,
                label: Text('$_prefix${'•' * i}'),
                enabled: !_running,
              ),
          ],
          selected: {_length},
          showSelectedIcon: false,
          onSelectionChanged: (s) => _setLength(s.first),
        ),
        const SizedBox(height: 10),
        Text(
          tr('onboarding.vanity.length_exist',
                  {'count': CallsignLengthFacts.grouped(facts.space)}) +
              (_length == kDefaultCallsignLength
                  ? ' ${tr('onboarding.vanity.length_default')}'
                  : ''),
          style:
              theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              facts.isWeak ? Icons.warning_amber_rounded : Icons.info_outline,
              size: 16,
              color: facts.isWeak ? cs.error : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                tr('onboarding.vanity.length_risk', {
                  'users': CallsignLengthFacts.grouped(facts.collideAfter),
                  'effort': facts.forgeEffort,
                }),
                style: theme.textTheme.bodySmall?.copyWith(
                    color: facts.isWeak ? cs.error : cs.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// What the list says before anything is found.
  String _emptyText() {
    if (_running) return tr('onboarding.vanity.searching');
    if (_gaveUp.isNotEmpty) return _gaveUp;
    // Without a callsign in play (a board not flashed yet, a group not made)
    // only the first line applies.
    final s = tr('onboarding.vanity.empty', {'callsign': widget.currentCallsign});
    return widget.currentCallsign.isEmpty ? s.split('\n').first : s;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final canSearch = _pattern.text.trim().isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text(tr('onboarding.vanity.title')),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () {
            _stop();
            Navigator.of(context).pop();
          },
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                tr('onboarding.vanity.intro'),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              Text(
                tr('onboarding.vanity.rarity'),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 6),
              Text(
                tr('onboarding.vanity.alphabet'),
                style: theme.textTheme.bodySmall?.copyWith(color: cs.tertiary),
              ),
              const SizedBox(height: 20),
              if (widget.fixedLength == null) ...[
                _lengthPicker(theme, cs),
                const SizedBox(height: 20),
              ],
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _pattern,
                      enabled: !_running,
                      autofocus: true,
                      textCapitalization: TextCapitalization.characters,
                      // A keyboard that does not compose, no suggestions: see
                      // _UpperCaseFormatter for what composing did here.
                      keyboardType: TextInputType.visiblePassword,
                      autocorrect: false,
                      enableSuggestions: false,
                      maxLength: _length,
                      // Only characters a callsign can actually contain — a
                      // pattern with a B in it would never, ever match.
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                          RegExp('[$kCallsignAlphabet'
                              '${kCallsignAlphabet.toLowerCase()}]'),
                        ),
                        _UpperCaseFormatter(),
                      ],
                      style: const TextStyle(
                          fontFamily: 'monospace', fontSize: 20),
                      decoration: InputDecoration(
                        labelText: tr('onboarding.vanity.pattern',
                            {'max': _length}),
                        hintText: tr('onboarding.vanity.pattern_hint'),
                        border: const OutlineInputBorder(),
                        counterText: '',
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) {
                        if (!_running && canSearch) _start();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    height: 56,
                    child: FilledButton.icon(
                      onPressed: _running
                          ? _stop
                          : (canSearch ? _start : null),
                      icon: Icon(_running ? Icons.stop : Icons.search),
                      label: Text(_running
                          ? tr('onboarding.vanity.stop')
                          : tr('common.search')),
                    ),
                  ),
                ],
              ),
              if (_running || _tried > 0) ...[
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (_running) ...[
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 10),
                    ],
                    Text(
                      tr('onboarding.vanity.tried',
                              {'count': _tried, 'time': _fmt(_elapsed)}) +
                          (_matches.isEmpty && _running
                              ? ' · ${tr('onboarding.vanity.still_looking')}'
                              : ''),
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Expanded(
                child: _matches.isEmpty
                    ? Center(
                        child: Text(
                          _emptyText(),
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium
                              ?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      )
                    : ListView.separated(
                        itemCount: _matches.length,
                        separatorBuilder: (context, i) =>
                            const Divider(height: 1),
                        itemBuilder: (context, i) {
                          final m = _matches[i];
                          return ListTile(
                            leading: CircleAvatar(
                              backgroundColor: cs.primaryContainer,
                              child: Icon(Icons.badge_outlined,
                                  color: cs.onPrimaryContainer, size: 20),
                            ),
                            title: Text(
                              m.callsign,
                              style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            subtitle: m.npub.length > 20
                                ? Text(
                                    '${m.npub.substring(0, 20)}…',
                                    style: const TextStyle(
                                        fontFamily: 'monospace', fontSize: 11),
                                  )
                                : null,
                            trailing: FilledButton(
                              onPressed: () => _use(m),
                              child: Text(tr('onboarding.vanity.use')),
                            ),
                            onTap: () => _use(m),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Uppercase as the user types, so the pattern always matches the callsign's own
/// casing (callsigns are uppercase; the npub they come from is not).
///
/// Never while the keyboard is composing: rewriting text an Android keyboard
/// still holds as a word in progress makes it re-send its own copy, and the
/// field doubles or drops letters (the profile screen's callsign field had
/// exactly this, 2026-10-24). The field also asks for a keyboard that does
/// not compose, so this almost never has to wait.
class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
      TextEditingValue oldValue, TextEditingValue newValue) {
    if (newValue.composing.isValid && !newValue.composing.isCollapsed) {
      return newValue;
    }
    final up = newValue.text.toUpperCase();
    return up == newValue.text ? newValue : newValue.copyWith(text: up);
  }
}
