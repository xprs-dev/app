import '../i18n/core_i18n.dart';
import '../preferences_service.dart';
import '../xprs/archiver_stats.dart';
import '../xprs/xprs_archive.dart';
import 'hero_item.dart';

/// The home hero's card about the Archiver: an invitation while this device
/// keeps only its own packets, a thank-you with its numbers once it is a
/// public archiver. A tap opens the Archiver page (launcher_page).
///
/// Not a [HeroSource] in the ranked pool: one card from the app itself would
/// either drown in posts or, scored as fresh, win every time. The feed pins
/// it at the second slot instead (HeroFeedService.refresh), so posts keep the
/// first and the carousel still rotates past it.
class ArchiverHeroCard {
  /// The card, or null when there is nothing worth saying (archive not
  /// open yet, or a public archiver that served nobody this week).
  static HeroItem? card({DateTime? now}) {
    final prefs = PreferencesService.instanceSync;
    final archive = XprsArchive.instance;
    if (prefs == null || !archive.ready) return null;
    final t = now ?? DateTime.now();
    if (!prefs.xprsPublicArchiver) {
      final kept = archive.countsByTier().total;
      return _item('invite', tr('archiver.hero.invite.title'),
          tr('archiver.hero.invite.body', {'n': _grouped(kept)}), t);
    }
    final week = ArchiverStats.instance.days.reversed.take(7);
    final answered = week.fold<int>(0, (s, d) => s + d.ans + d.mail);
    if (answered == 0) return null;
    return _item(
        'thanks',
        tr('archiver.hero.thanks.title'),
        tr('archiver.hero.thanks.body', {
          'n': _grouped(answered),
          'size': _size(archive.spoolBytes),
        }),
        t);
  }

  static HeroItem _item(String key, String title, String body, DateTime t) =>
      HeroItem(
        id: '$kHeroSourceArchiver:$key',
        sourceId: kHeroSourceArchiver,
        title: title,
        summary: body,
        createdAt: t,
        authorName: tr('launcher.drawer.archiver'),
      );

  static String _grouped(int n) {
    final s = '$n';
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write(' ');
      b.write(s[i]);
    }
    return b.toString();
  }

  static String _size(int bytes) {
    if (bytes >= 1 << 30) return '${(bytes / (1 << 30)).toStringAsFixed(1)} GB';
    if (bytes >= 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(0)} MB';
    return '${(bytes / 1024).ceil()} KB';
  }
}

const String kHeroSourceArchiver = 'archiver';
