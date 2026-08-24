import '../xprs/xprs_archive.dart';
import 'hero_item.dart';
import 'hero_source.dart';

/// The launcher hero, fed by what the RADIO heard.
///
/// A `t:status` is this network's post (docs/XPRS.md section 27): a station
/// says something, it travels by Bluetooth, LoRa, LAN and the mesh, and every
/// station that hears it archives it. That is the traffic this device exists
/// to carry, so that is what the hero shows — the public NOSTR firehose it
/// used to show came from the internet and had nothing to do with the network
/// the user is standing in.
///
/// Cheap by construction: one indexed query over the archive the station is
/// already keeping, called at most once per refresh while the launcher is on
/// screen (docs/performance.md section 4.2).
class XprsStatusHeroSource implements HeroSource {
  /// How far back a status stays hero-worthy. Older than this and it is
  /// history, not news.
  static const Duration window = Duration(days: 3);

  /// Enough to give the ranker a choice without asking the archive for a page
  /// nobody will look at.
  static const int limit = 24;

  @override
  String get id => kHeroSourceXprsStatus;

  @override
  Future<List<HeroItem>> candidates() async {
    final archive = XprsArchive.instance;
    if (!archive.ready) return const [];
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = archive.query(
      sinceMs: now - window.inMilliseconds,
      types: const ['status'],
      limit: limit,
    );
    final out = <HeroItem>[];
    for (final r in rows) {
      final text = messageOf(r['wire'] as String? ?? '');
      if (text.isEmpty) continue;
      final from = (r['from'] as String? ?? '').trim();
      if (from.isEmpty) continue;
      final tsMs = ((r['ts'] as int?) ?? 0) * 1000;
      out.add(HeroItem(
        id: '$kHeroSourceXprsStatus:${r['id']}',
        sourceId: kHeroSourceXprsStatus,
        // The callsign is the headline: on this network you know a station by
        // its callsign long before you know a name for it.
        title: from,
        summary: text,
        createdAt: DateTime.fromMillisecondsSinceEpoch(tsMs),
        authorName: from,
        // Tapping it opens whichever wapp declares `social` -- the one that
        // owns statuses on this network. Routed by INTENT, not by a folder
        // name: the launcher resolves a non-wapp hero item that way, and a
        // card whose intent it cannot resolve is dropped as dead.
        intent: 'social',
      ));
    }
    return out;
  }

  /// Everything after ` m:` — a status body runs to the end of the packet
  /// (section 2), spaces and colons included.
  static String messageOf(String wire) {
    const key = ' m:';
    final i = wire.indexOf(key);
    if (i < 0) return '';
    return wire.substring(i + key.length).trim();
  }
}
