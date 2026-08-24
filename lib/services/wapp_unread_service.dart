import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Per-wapp unread counts that drive launcher badges. Counts are session-scoped
/// and in-memory. Base keys are `wappId`; intent-specific counts use
/// `wappId#intent` so host icons can distinguish "mail" from "chat" even
/// when one wapp provides both views.
class WappUnreadService {
  WappUnreadService._();
  static final WappUnreadService instance = WappUnreadService._();

  /// composite key -> unread count (entries with 0 are removed).
  final ValueNotifier<Map<String, int>> counts =
      ValueNotifier<Map<String, int>>(const {});

  String _key(String wappId, String? intent) {
    final cleanIntent = intent?.trim().toLowerCase();
    if (cleanIntent == null || cleanIntent.isEmpty) return wappId;
    return '$wappId#$cleanIntent';
  }

  int countFor(String wappId, {String? intent}) =>
      counts.value[_key(wappId, intent)] ?? 0;

  /// What this wapp's tile should show.
  ///
  /// The base key and the intent keys are two VIEWS of the same unread, written
  /// by two authorities -- the host's conversation stores write the base key,
  /// the wapp's own `unread` message writes its intent key -- so adding them
  /// counted the same messages twice (the mail tile read double whenever the
  /// mail page was open). Take the larger instead: for a wapp that publishes
  /// several genuinely distinct intents their sum is still the number, and for
  /// two views of one total the answer is that total.
  int totalFor(String wappId) {
    final base = counts.value[wappId] ?? 0;
    final prefix = '$wappId#';
    var intents = 0;
    for (final e in counts.value.entries) {
      if (e.key.startsWith(prefix)) intents += e.value;
    }
    return math.max(base, intents);
  }

  /// What a host icon dedicated to [intent] should show: the wapp's own count
  /// for that intent, or -- when the wapp publishes no intent key at all -- the
  /// wapp's total. The chat wapp never sends an `unread` message, so its
  /// intent key is never written and reading it alone reported zero forever
  /// while the host's conversation stores held the real number.
  int badgeFor(String wappId, String intent) =>
      counts.value[_key(wappId, intent)] ?? totalFor(wappId);

  /// Set the authoritative count for [wappId]; 0/negative clears it.
  void setCount(String wappId, int n, {String? intent}) {
    final key = _key(wappId, intent);
    if ((counts.value[key] ?? 0) == (n > 0 ? n : 0)) return;
    final m = Map<String, int>.from(counts.value);
    if (n > 0) {
      m[key] = n;
    } else {
      m.remove(key);
    }
    counts.value = m;
  }

  void add(String wappId, int n, {String? intent}) =>
      setCount(wappId, countFor(wappId, intent: intent) + n, intent: intent);

  void clear(String wappId, {String? intent}) =>
      setCount(wappId, 0, intent: intent);

  void clearAll(String wappId) {
    final prefix = '$wappId#';
    final m = Map<String, int>.from(counts.value);
    final before = m.length;
    m.removeWhere((key, _) => key == wappId || key.startsWith(prefix));
    if (m.length == before) return;
    counts.value = m;
  }
}
