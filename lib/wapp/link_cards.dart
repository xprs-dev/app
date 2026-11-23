/*
 * link_cards — a shared link travels with its preview, made once by the
 * sender.
 *
 * Whoever receives a link should see what it is (the page's picture, title
 * and a few words) without their device contacting the site: a preview
 * fetched by each reader tells the site who every reader is. So the SENDER's
 * device asks the `link.card` functionality (the Link cards wapp,
 * apps/linkcard, in the System folder) while the message is being written,
 * and the preview goes out as an ordinary message: the words with the link,
 * the page's title and summary on a line after them, and the page's picture
 * as the message's one small attachment (XPRS.md 7.7.7), nothing else.
 *
 * Nothing here fetches anything: the wapp does, through its own HAL, and a
 * reader's screen only ever draws what arrived.
 */
import 'dart:async';

import '../services/media/media_preview.dart';
import '../util/media_ref.dart';
import 'functionality_broker.dart';

/// What the wapp answered for one link.
class LinkCard {
  const LinkCard({
    required this.url,
    required this.title,
    required this.summary,
    required this.site,
    this.token,
  });

  final String url;
  final String title;
  final String summary;
  final String site;

  /// The picture's media token (`file:<sha>.<ext>`), or null when the page
  /// had none to give.
  final String? token;

  LinkCard withToken(String? t) =>
      LinkCard(url: url, title: title, summary: summary, site: site, token: t);

  static LinkCard? fromResult(Map<String, dynamic> r) {
    String s(String k) => (r[k] is String) ? (r[k] as String).trim() : '';
    final card = LinkCard(
      url: s('url'),
      title: s('title'),
      summary: s('summary'),
      site: s('site'),
      token: s('file').startsWith('file:') ? s('file') : null,
    );
    return card.title.isEmpty && card.summary.isEmpty ? null : card;
  }
}

class LinkCards {
  LinkCards._();
  static final LinkCards instance = LinkCards._();

  /// The functionality the wapp provides.
  static const functionality = 'link.card';

  /// The preview's own words never take more than this.
  static const maxCardChars = 200;

  /// The longest message the composer sends with a preview on it; past this
  /// the words go alone.
  static const maxMessageChars = 880;

  static final RegExp _url =
      RegExp(r"""https?://[^\s<>"'`]+""", caseSensitive: false);

  /// The first web address in [text], without the punctuation a sentence
  /// puts after it. Null when there is none.
  static String? firstUrl(String text) {
    final m = _url.firstMatch(text);
    if (m == null) return null;
    var u = m[0]!;
    while (u.isNotEmpty && '.,;:!?)]}'.contains(u[u.length - 1])) {
      // A closing bracket the address itself opened stays.
      final last = u[u.length - 1];
      if (last == ')' && '('.allMatches(u).length >= ')'.allMatches(u).length) {
        break;
      }
      u = u.substring(0, u.length - 1);
    }
    return u.length > 10 ? u : null;
  }

  /// Answers by address, so typing around a link does not ask twice.
  final Map<String, Future<LinkCard?>> _cards = {};

  /// The preview for [url], or null when there is none to be had (no wapp,
  /// switched off, the page did not answer or says nothing). Never throws.
  Future<LinkCard?> cardFor(String url) {
    final hit = _cards[url];
    if (hit != null) return hit;
    if (_cards.length >= 32) _cards.remove(_cards.keys.first);
    final f = FunctionalityBroker.instance
        .ask(functionality, {'url': url}, caller: 'chat')
        .then(LinkCard.fromResult)
        .then((c) async => c?.withToken(await _small(c.token)))
        .catchError((Object _) => null);
    _cards[url] = f;
    // A failure is not remembered: the page may answer in a minute.
    f.then((c) {
      if (c == null) _cards.remove(url);
    });
    return f;
  }

  /// The picture to attach: the small preview the media store makes of what
  /// the wapp downloaded, so the message carries one small file like any
  /// shared picture, and the full-size download is dropped. A picture
  /// already small is attached as it is; one that cannot be made small is
  /// left out.
  static Future<String?> _small(String? token) async {
    if (token == null) return null;
    final ref = MediaRef.parse(token);
    final archive = MediaPreviews.instance.archive?.call();
    if (ref == null || archive == null) return null;
    final preview = await MediaPreviews.instance.ensureFor(token);
    if (preview != null) {
      archive.delete(ref.sha256);
      return preview;
    }
    final size = archive.getMeta(ref.sha256)?.size ?? 0;
    if (size > 0 && size <= kPreviewMaxBytes) return token;
    archive.delete(ref.sha256);
    return null;
  }

  /// [text] with [card]'s title and summary on a line after it, cut to fit,
  /// or [text] alone when it would not fit.
  static String withCard(String text, LinkCard card) {
    String plain(String s) =>
        s.replaceAll(RegExp(r'[\u2028\u2029\r\n\t]+'), ' ').trim();
    final title = plain(card.title);
    var summary = plain(card.summary);
    // Many pages put the start of their summary in the title already
    // ("GitHub - owner/repo: Flutter makes it easy…"): said once is enough.
    final head = summary.length > 40 ? summary.substring(0, 40) : summary;
    if (head.isNotEmpty &&
        title.toLowerCase().contains(head.toLowerCase().replaceAll('…', ''))) {
      summary = '';
    }
    String build() => [
          if (title.isNotEmpty) title,
          if (summary.isNotEmpty) summary,
        ].join(' — ');
    var line = build();
    while (line.length > maxCardChars && summary.isNotEmpty) {
      final cut = summary.length - (line.length - maxCardChars) - 1;
      if (cut < 20) {
        summary = '';
      } else {
        final sp = summary.lastIndexOf(' ', cut);
        summary = '${summary.substring(0, sp > 20 ? sp : cut).trimRight()}…';
      }
      line = build();
    }
    if (line.isEmpty || line.length > maxCardChars) return text;
    // A line break as the composer writes one (XPRS.md 4.11).
    final out = '$text\u2028$line';
    return out.length > maxMessageChars ? text : out;
  }
}
