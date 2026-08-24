import 'dart:convert';

import '../../profile/storage_paths.dart';
import '../preferences_service.dart';
import '../xprs/xprs_archive.dart';
import 'hero_item.dart';
import 'hero_source.dart';

/// The launcher hero, fed by what this network is saying.
///
/// A `t:status` is this network's public post (docs/XPRS.md section 27): a
/// station says something, it travels by Bluetooth, LoRa, LAN, the mesh and
/// the hubs, and every station that hears it archives it. That is the traffic
/// this device exists to carry, so that is what the hero shows -- the public
/// NOSTR firehose it used to show came off the internet and said nothing about
/// the network the user is standing in.
///
/// Two modes, and the user chooses between them just by using the app:
///
///  * **Nobody followed yet** -- show everything, ranked by POPULARITY. A
///    newcomer has no way to know which callsigns are worth reading, so the
///    network's own judgement stands in for theirs: a status carries the
///    likes it has collected (`t:reaction add:like`, section 6.5) and the
///    ranker scores on them.
///  * **Following somebody** -- show only those callsigns. A follow is a
///    statement about whose news matters, and once it exists, popularity is
///    the wrong question: the hero becomes highlights from the people the
///    user chose. The follow list is the social wapp's own
///    (`xprs.follow.calls`), so following in the wapp changes the hero with
///    no second list to keep in step.
///
/// Cheap by construction: two indexed queries over a spool the station is
/// already keeping, at most once per refresh and only while the launcher is on
/// screen (docs/performance.md section 4.2).
class XprsStatusHeroSource implements HeroSource {
  /// How far back a status stays hero-worthy. Older than this is history, not
  /// news. Wider when following, because a handful of chosen callsigns post
  /// far less often than a whole network does.
  static const Duration window = Duration(days: 3);
  static const Duration followedWindow = Duration(days: 14);

  /// Enough for the ranker to have a real choice without asking the archive
  /// for a page nobody will look at.
  static const int limit = 120;

  /// The social wapp's follow list: `CALL,CALL,CALL` under this key in its own
  /// key-value store. Read, never written -- the wapp owns it.
  static const String followWapp = 'social';
  static const String followKey = 'xprs.follow.calls';

  @override
  String get id => kHeroSourceXprsStatus;

  @override
  Future<List<HeroItem>> candidates() async {
    final archive = XprsArchive.instance;
    if (!archive.ready) return const [];

    final follows = await _follows();
    final now = DateTime.now().millisecondsSinceEpoch;
    final since = now -
        (follows.isEmpty ? window : followedWindow).inMilliseconds;

    final rows = archive.query(
      sinceMs: since,
      types: const ['status'],
      limit: limit,
    );
    if (rows.isEmpty) return const [];

    // Popularity only matters while nothing has been followed; when it has,
    // the choice is already made and this query is skipped entirely.
    final likes = follows.isEmpty ? _likeCounts(archive, since) : const {};

    final out = <HeroItem>[];
    for (final r in rows) {
      final from = (r['from'] as String? ?? '').trim();
      if (from.isEmpty) continue;
      if (follows.isNotEmpty && !follows.contains(from.toUpperCase())) continue;
      final text = messageOf(r['wire'] as String? ?? '');
      if (text.isEmpty) continue;
      final rowId = (r['id'] ?? '').toString();
      out.add(HeroItem(
        id: '$kHeroSourceXprsStatus:$rowId',
        sourceId: kHeroSourceXprsStatus,
        // The callsign is the headline: on this network you know a station by
        // its callsign long before you know a name for it.
        title: from,
        summary: text,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(((r['ts'] as int?) ?? 0) * 1000),
        authorName: from,
        // Feeds the ranker's engagement score, which is what makes the
        // no-follows view a popularity view.
        likes: likes[rowId] ?? 0,
        // A followed callsign is not competing on popularity -- it was chosen.
        priority: follows.isEmpty ? 0 : 2,
        // Tapping it opens whichever wapp declares `social` -- the one that
        // owns statuses. Routed by INTENT, not by a folder name: that is how
        // the launcher resolves a hero item with no wapp behind it, and a card
        // whose intent it cannot resolve is dropped as dead.
        intent: 'social',
      ));
    }
    return out;
  }

  /// Likes per status, from the reactions this station has archived.
  ///
  /// A reaction names its target in `r:` (section 6.5) and either adds or
  /// removes the like, so an unliked post does not keep the credit. Counted
  /// per author so one station cannot like the same post into the hero.
  static Map<String, int> _likeCounts(XprsArchive archive, int sinceMs) =>
      _tally(archive.query(
        sinceMs: sinceMs,
        types: const ['reaction'],
        limit: 500,
      ));

  static Map<String, int> _tally(List<Map<String, dynamic>> rows) {
    final added = <String, Set<String>>{};
    final removed = <String, Set<String>>{};
    for (final r in rows) {
      final wire = r['wire'] as String? ?? '';
      final target = _field(wire, 'r');
      if (target.isEmpty) continue;
      final who = (r['from'] as String? ?? '').trim().toUpperCase();
      if (who.isEmpty) continue;
      if (_field(wire, 'add') == 'like') {
        (added[target] ??= <String>{}).add(who);
      } else if (_field(wire, 'remove') == 'like') {
        (removed[target] ??= <String>{}).add(who);
      }
    }
    final out = <String, int>{};
    added.forEach((target, whos) {
      final n = whos.difference(removed[target] ?? const <String>{}).length;
      if (n > 0) out[target] = n;
    });
    return out;
  }

  /// Tests: the like tally over already-fetched rows, without an archive.
  static Map<String, int> debugLikeCounts(List<Map<String, dynamic>> rows) =>
      _tally(rows);

  /// The callsigns the user follows, upper-cased. Empty when the social wapp
  /// has never been opened or nobody has been followed.
  static Future<Set<String>> _follows() async {
    final prefs = PreferencesService.instanceSync;
    if (prefs == null) return const {};
    try {
      final raw =
          await wappDataStorageFor(prefs, followWapp).readString('kv.json');
      if (raw == null || raw.isEmpty) return const {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const {};
      final list = decoded[followKey];
      if (list is! String) return const {};
      return list
          .split(',')
          .map((c) => c.trim().toUpperCase())
          .where((c) => c.isNotEmpty)
          .toSet();
    } catch (_) {
      return const {};
    }
  }

  /// Everything after ` m:` — a status body runs to the end of the packet
  /// (section 2), spaces and colons included.
  static String messageOf(String wire) {
    const key = ' m:';
    final i = wire.indexOf(key);
    if (i < 0) return '';
    return wire.substring(i + key.length).trim();
  }

  /// One space-delimited `key:value` out of a wire, before any ` m:`.
  static String _field(String wire, String key) {
    final head = wire.split(' m:').first;
    for (final tok in head.split(' ')) {
      final c = tok.indexOf(':');
      if (c > 0 && tok.substring(0, c) == key) return tok.substring(c + 1);
    }
    return '';
  }
}
