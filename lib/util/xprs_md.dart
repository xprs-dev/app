// Formatted text (XPRS.md 4.11): the small Markdown a t:blog carries and a
// reader MAY apply to a t:message. A port of the web chat's page/xprs_md.js
// (mdRender / mdInline / mdEmph), so a message reads the same in the app and
// in the browser. Pure Dart: it turns text into blocks of styled spans and
// draws nothing (lib/wapp/geoui/widgets/xprs_md_text.dart draws them).
//
// Read: `# ` `## ` `### ` headings, **bold**, *italic* / _italic_ (not inside
// a word, so snake_case stays), ~~struck~~, `code`, lists (- * + and 1.),
// > quotes, a --- rule, [words](https://...) and a bare https:// link, and
// [words](<ref>) / ![words](<ref>) content references. Only http and https
// become links; anything else stays text. U+2028 is a line break and U+2029
// a paragraph break on the wire; a plain newline is read the same way.

/// One run of text with one look.
class XprsMdSpan {
  const XprsMdSpan(this.text,
      {this.bold = false,
      this.italic = false,
      this.strike = false,
      this.code = false,
      this.url,
      this.ref});
  final String text;
  final bool bold, italic, strike, code;

  /// An http(s) link this run opens.
  final String? url;

  /// A content reference (7.7 `ref`) this run names: an image's alt text or
  /// a file's label.
  final String? ref;

  XprsMdSpan _with(String t) => XprsMdSpan(t,
      bold: bold,
      italic: italic,
      strike: strike,
      code: code,
      url: url,
      ref: ref);

  @override
  String toString() => [
        text,
        if (bold) 'b',
        if (italic) 'i',
        if (strike) 's',
        if (code) 'c',
        if (url != null) 'u=$url',
        if (ref != null) 'r=$ref',
      ].join('|');
}

enum XprsMdBlockKind { paragraph, heading, quote, bullets, numbers, rule }

/// A paragraph (its lines), a heading (one line, [level] 1 to 3), a quote
/// (its lines), a list (one line per item) or a rule (no lines).
class XprsMdBlock {
  const XprsMdBlock(this.kind, this.lines, {this.level = 0});
  final XprsMdBlockKind kind;
  final List<List<XprsMdSpan>> lines;
  final int level;
}

final _ref = RegExp(r'^(?:[A-Za-z0-9_-]{43}|[0-9a-f]{64})\.[a-z0-9]{1,8}$');
final _httpUrl = RegExp(r'''^https?://[^\s<>"']+$''', caseSensitive: false);

/// Whether [s] is a content reference (XPRS.md 7.7 `ref`).
bool xprsMdIsRef(String s) => _ref.hasMatch(s);

/// Whether [text] holds anything [parseXprsMd] reads beyond plain words, so
/// a caller can keep its plain-text path for the common message.
bool xprsMdHasMarkup(String text) => _markup.hasMatch(text);
final _markup = RegExp(
    r'[*_~`\[  \n]|https?://|^\s*(#{1,3}\s|>|[-+]\s|\d{1,3}[.)]\s|-{3,}$)',
    caseSensitive: false,
    multiLine: true);

/// The whole text -> blocks (mdRender).
List<XprsMdBlock> parseXprsMd(String text) {
  final lines = text
      .replaceAll(RegExp(r'\r\n?'), '\n')
      .replaceAll(RegExp(' ?  ?'), '\n\n')
      .replaceAll(RegExp(' ?  ?'), '\n')
      .split('\n');
  final out = <XprsMdBlock>[];
  var para = <String>[], quote = <String>[];
  List<String>? list;
  var ordered = false;
  void flush() {
    if (para.isNotEmpty) {
      out.add(XprsMdBlock(
          XprsMdBlockKind.paragraph, [for (final l in para) parseXprsMdInline(l)]));
      para = [];
    }
    if (list != null) {
      out.add(XprsMdBlock(
          ordered ? XprsMdBlockKind.numbers : XprsMdBlockKind.bullets,
          [for (final l in list!) parseXprsMdInline(l)]));
      list = null;
    }
    if (quote.isNotEmpty) {
      out.add(XprsMdBlock(
          XprsMdBlockKind.quote, [for (final l in quote) parseXprsMdInline(l)]));
      quote = [];
    }
  }

  for (final raw in lines) {
    final l = raw.trim();
    if (l.isEmpty) {
      flush();
      continue;
    }
    RegExpMatch? m;
    if ((m = RegExp(r'^(#{1,3})\s+(.+)$').firstMatch(l)) != null) {
      flush();
      out.add(XprsMdBlock(XprsMdBlockKind.heading, [parseXprsMdInline(m!.group(2)!)],
          level: m.group(1)!.length));
      continue;
    }
    if (RegExp(r'^(?:-{3,}|\*{3,}|_{3,})$').hasMatch(l)) {
      flush();
      out.add(const XprsMdBlock(XprsMdBlockKind.rule, []));
      continue;
    }
    if ((m = RegExp(r'^>\s?(.*)$').firstMatch(l)) != null) {
      if (para.isNotEmpty || list != null) flush();
      quote.add(m!.group(1)!);
      continue;
    }
    m = RegExp(r'^[-*+]\s+(.+)$').firstMatch(l) ??
        RegExp(r'^\d{1,3}[.)]\s+(.+)$').firstMatch(l);
    if (m != null) {
      final num = RegExp(r'^\d').hasMatch(l);
      if (para.isNotEmpty || quote.isNotEmpty || (list != null && ordered != num)) {
        flush();
      }
      if (list == null) {
        list = [];
        ordered = num;
      }
      list!.add(m.group(1)!);
      continue;
    }
    if (list != null || quote.isNotEmpty) flush();
    para.add(l);
  }
  flush();
  return out;
}

// Pieces read before emphasis (mdInline): nothing inside them is emphasis.
final _code = RegExp(r'`([^`]+)`');
final _image = RegExp(r'!\[([^\]]*)\]\(([^)\s]+)\)');
final _link = RegExp(r'\[([^\]]+)\]\(([^)\s]+)\)');
// A bare link never ends in sentence punctuation or an emphasis mark, so
// "**https://a.org**" is a bold link (page/xprs_md.js still keeps the "**").
final _bare = RegExp(r'''\bhttps?://[^\s<>"'()\u0000]+[^\s<>"'().,;:!?*~\u0000]''',
    caseSensitive: false);
final _slot = RegExp(r'\u0000(\d+)\u0000');

// Emphasis (mdEmph), tried earliest-first, bold before italic at a tie.
final _emph = <(RegExp, XprsMdSpan Function(XprsMdSpan))>[
  (RegExp(r'\*\*(?=\S)([^*]*?\S)\*\*'), (s) => _style(s, bold: true)),
  (RegExp(r'~~(?=\S)([^~]*?\S)~~'), (s) => _style(s, strike: true)),
  (RegExp(r'(?<![*\w])\*(?=\S)([^*]*?\S)\*(?![*\w])'), (s) => _style(s, italic: true)),
  (RegExp(r'(?<!\w)_(?=\S)([^_]*?\S)_(?!\w)'), (s) => _style(s, italic: true)),
];

XprsMdSpan _style(XprsMdSpan s,
        {bool bold = false, bool italic = false, bool strike = false}) =>
    XprsMdSpan(s.text,
        bold: s.bold || bold,
        italic: s.italic || italic,
        strike: s.strike || strike,
        code: s.code,
        url: s.url,
        ref: s.ref);

/// One line -> spans (mdInline).
List<XprsMdSpan> parseXprsMdInline(String line) {
  // Each protected piece becomes \0N\0 in the text and its spans go in kept[N].
  final kept = <List<XprsMdSpan>>[];
  String put(List<XprsMdSpan> spans) {
    kept.add(spans);
    return '\u0000${kept.length - 1}\u0000';
  }

  var s = line.replaceAll('\u0000', '');
  s = s.replaceAllMapped(
      _code, (m) => put([XprsMdSpan(m.group(1)!, code: true)]));
  s = s.replaceAllMapped(_image, (m) {
    final alt = m.group(1)!, r = m.group(2)!;
    if (!xprsMdIsRef(r)) return m.group(0)!;
    return put([XprsMdSpan(alt.isEmpty ? r : alt, ref: r)]);
  });
  s = s.replaceAllMapped(_link, (m) {
    final label = m.group(1)!, u = m.group(2)!;
    if (xprsMdIsRef(u)) return put([XprsMdSpan(label, ref: u)]);
    if (!_httpUrl.hasMatch(u)) return m.group(0)!;
    return put(_emphasis(label, XprsMdSpan('', url: u), const []));
  });
  s = s.replaceAllMapped(
      _bare, (m) => put([XprsMdSpan(m.group(0)!, url: m.group(0)!)]));
  return _merge(_emphasis(s, const XprsMdSpan(''), kept));
}

/// Read emphasis in [s] with the look of [base]; \0N\0 slots expand to kept[N].
List<XprsMdSpan> _emphasis(
    String s, XprsMdSpan base, List<List<XprsMdSpan>> kept) {
  final out = <XprsMdSpan>[];
  var at = 0;
  while (at < s.length) {
    RegExpMatch? best;
    XprsMdSpan Function(XprsMdSpan)? how;
    for (final (re, f) in _emph) {
      final m = re.allMatches(s, at).firstOrNull;
      if (m != null && (best == null || m.start < best.start)) {
        best = m;
        how = f;
      }
    }
    if (best == null) break;
    _plain(s.substring(at, best.start), base, kept, out);
    out.addAll(_emphasis(best.group(1)!, how!(base), kept));
    at = best.end;
  }
  _plain(s.substring(at), base, kept, out);
  return out;
}

void _plain(String s, XprsMdSpan base, List<List<XprsMdSpan>> kept,
    List<XprsMdSpan> out) {
  var at = 0;
  for (final m in _slot.allMatches(s)) {
    if (m.start > at) out.add(base._with(s.substring(at, m.start)));
    final i = int.parse(m.group(1)!);
    if (i < kept.length) {
      for (final k in kept[i]) {
        // A protected piece inside emphasis takes the emphasis too.
        out.add(XprsMdSpan(k.text,
            bold: k.bold || base.bold,
            italic: k.italic || base.italic,
            strike: k.strike || base.strike,
            code: k.code,
            url: k.url,
            ref: k.ref));
      }
    }
    at = m.end;
  }
  if (at < s.length) out.add(base._with(s.substring(at)));
}

/// Neighbours with the same look become one span.
List<XprsMdSpan> _merge(List<XprsMdSpan> spans) {
  final out = <XprsMdSpan>[];
  for (final s in spans) {
    if (s.text.isEmpty) continue;
    final p = out.isEmpty ? null : out.last;
    if (p != null &&
        p.bold == s.bold &&
        p.italic == s.italic &&
        p.strike == s.strike &&
        p.code == s.code &&
        p.url == s.url &&
        p.ref == s.ref) {
      out[out.length - 1] = p._with(p.text + s.text);
    } else {
      out.add(s);
    }
  }
  return out;
}
