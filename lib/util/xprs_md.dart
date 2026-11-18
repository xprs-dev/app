// Formatted text (XPRS.md 4.11) for the Flutter app (Android, desktop): the
// ONE Dart reader of the small Markdown a t:blog carries and a reader MAY
// apply to a t:message. Every Flutter surface that shows a post or a message
// body reads it here (XprsMdText draws the spans); no other Dart copy.
//
// The inline reader works on escaped text and writes HTML first (the same
// steps a browser reader would take), and [parseXprsMd] reads that HTML back
// into styled spans, so the order of the rules lives in one place.
//
// Read: `# ` `## ` `### ` headings, **bold**, *italic* / _italic_ (not inside
// a word, so snake_case stays), ~~struck~~, `code`, lists (- * + and 1.),
// > quotes, a --- rule, [words](https://...) and a bare https:// link, @CALL
// mentions, and [words](<ref>) / ![words](<ref>) content references. Only
// http and https become links. Everything else is escaped. U+2028 is a line
// break and U+2029 a paragraph break on the wire; a newline reads the same.

const String xprsMdLineSep = ' ';
const String xprsMdParaSep = ' ';

const _imageExt = {'jpg', 'jpeg', 'png', 'gif', 'webp', 'avif', 'bmp'};
final _refRe = RegExp(r'^(?:[A-Za-z0-9_-]{43}|[0-9a-f]{64})\.[a-z0-9]{1,8}$');

/// Whether [s] is a content reference (XPRS.md 7.7 `ref`): base64url or hex
/// SHA-256, a dot, the type.
bool xprsMdIsRef(String s) => _refRe.hasMatch(s);

/// Whether [s] is a reference to a picture (by its type).
bool xprsMdIsImageRef(String s) =>
    xprsMdIsRef(s) && _imageExt.contains(s.split('.').last);

/// Composer text -> what m: carries: newlines become the
/// separators, spaces around them go, other control characters become a space.
String xprsMdToWire(String t) => t
    .replaceAll(RegExp(r'\r\n?'), '\n')
    .replaceAll(RegExp(r'[ \t]*\n[ \t]*'), '\n')
    .trim()
    .replaceAll(RegExp(r'\n{2,}'), xprsMdParaSep)
    .replaceAll('\n', xprsMdLineSep)
    .replaceAll(RegExp(r'[\x00-\x1f\x7f]+'), ' ');

/// And back, for editing a post again.
String xprsMdFromWire(String t) => t
    .replaceAll(RegExp(' ?  ?'), '\n\n')
    .replaceAll(RegExp(' ?  ?'), '\n');

/// HTML-escape.
String xprsMdEscape(String t) => t
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');

String _unescape(String t) => t
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&');

/// Every reference the text names, images and files, in order, once each
///.
List<String> xprsMdRefs(String text) {
  final out = <String>[];
  for (final m in RegExp(
          r'\]\(([A-Za-z0-9_-]{43}\.[a-z0-9]{1,8}|[0-9a-f]{64}\.[a-z0-9]{1,8})\)')
      .allMatches(text)) {
    final r = m.group(1)!;
    if (!out.contains(r)) out.add(r);
  }
  return out;
}

/// Whether [text] holds anything the reader turns into more than plain words,
/// so a caller can keep its plain-text path for the common message.
bool xprsMdHasMarkup(String text) => _markup.hasMatch(text);
final _markup = RegExp(
    r'[*_~`\[@  \n]|https?://|^\s*(#{1,3}\s|>|[-+]\s|\d{1,3}[.)]\s|-{3,}$)',
    caseSensitive: false,
    multiLine: true);

/// How references and mentions become HTML; each callback returns HTML and
/// escapes what it puts in. Unset: a reference shows its words, a mention
/// stays text .
class XprsMdHtml {
  const XprsMdHtml({this.img, this.file, this.mention});
  final String Function(String ref, String alt)? img;
  final String Function(String ref, String label)? file;
  final String Function(String call)? mention;
}

// ---- inline ---------------------------------------------------------------

final _code = RegExp(r'`([^`]+)`');
final _image = RegExp(r'!\[([^\]]*)\]\(([^)\s]+)\)');
final _link = RegExp(r'\[([^\]]+)\]\(([^)\s]+)\)');
final _httpOnly = RegExp(r'''^https?://[^\s<>"']+$''', caseSensitive: false);
// A bare link never ends in sentence punctuation or an emphasis mark, so
// "**https://a.org**" is a bold link.
final _bare = RegExp(
    r'''\bhttps?://[^\s<>"'()\u0000]+[^\s<>"'().,;:!?*~\u0000]''',
    caseSensitive: false);
final _mention = RegExp(
    r'(^|[^A-Za-z0-9_@])@([A-Z0-9][A-Z0-9/-]*[A-Z0-9]|[A-Z0-9])(?![a-z])');
final _slot = RegExp(r'\u0000(\d+)\u0000');

String _anchor(String url, String inner) =>
    '<a href="${xprsMdEscape(url)}" target="_blank" '
    'rel="noopener nofollow">$inner</a>';

/// Emphasis on escaped text.
String _emph(String s) => s
    .replaceAllMapped(RegExp(r'\*\*(?=\S)([^*]*?\S)\*\*'),
        (m) => '<strong>${m[1]}</strong>')
    .replaceAllMapped(
        RegExp(r'~~(?=\S)([^~]*?\S)~~'), (m) => '<del>${m[1]}</del>')
    .replaceAllMapped(RegExp(r'(^|[^*\w])\*(?=\S)([^*]*?\S)\*(?![*\w])'),
        (m) => '${m[1]}<em>${m[2]}</em>')
    .replaceAllMapped(RegExp(r'(^|[^\w])_(?=\S)([^_]*?\S)_(?!\w)'),
        (m) => '${m[1]}<em>${m[2]}</em>');

/// One line of text -> HTML.
String xprsMdInlineHtml(String line, [XprsMdHtml opts = const XprsMdHtml()]) {
  final keep = <String>[];
  String put(String h) {
    keep.add(h);
    return '\u0000${keep.length - 1}\u0000';
  }

  var s = line.replaceAll('\u0000', '');
  s = s.replaceAllMapped(
      _code, (m) => put('<code>${xprsMdEscape(m[1]!)}</code>'));
  s = s.replaceAllMapped(_image, (m) {
    final all = m[0]!, alt = m[1]!, r = m[2]!;
    if (!xprsMdIsRef(r)) return all;
    if (xprsMdIsImageRef(r) && opts.img != null) return put(opts.img!(r, alt));
    if (opts.file != null) return put(opts.file!(r, alt.isEmpty ? r : alt));
    return put(xprsMdEscape(all));
  });
  s = s.replaceAllMapped(_link, (m) {
    final all = m[0]!, label = m[1]!, u = m[2]!;
    if (xprsMdIsRef(u)) {
      return put(opts.file != null ? opts.file!(u, label) : xprsMdEscape(label));
    }
    if (!_httpOnly.hasMatch(u)) return all;
    return put(_anchor(u, _emph(xprsMdEscape(label))));
  });
  s = s.replaceAllMapped(
      _bare, (m) => put(_anchor(m[0]!, xprsMdEscape(m[0]!))));
  final mention = opts.mention;
  if (mention != null) {
    s = s.replaceAllMapped(_mention, (m) => '${m[1]}${put(mention(m[2]!))}');
  }
  s = _emph(xprsMdEscape(s));
  return s.replaceAllMapped(_slot, (m) => keep[int.parse(m[1]!)]);
}

// ---- blocks ---------------------------------------------------------------

enum XprsMdBlockKind { paragraph, heading, quote, bullets, numbers, rule }

/// A block with its lines as written (inline formatting not yet read).
class XprsMdRawBlock {
  const XprsMdRawBlock(this.kind, this.lines, {this.level = 0});
  final XprsMdBlockKind kind;
  final List<String> lines;
  final int level;
}

/// The whole text -> blocks of raw lines.
List<XprsMdRawBlock> xprsMdBlocks(String text) {
  final lines = xprsMdFromWire(text.replaceAll(RegExp(r'\r\n?'), '\n'))
      .split('\n');
  final out = <XprsMdRawBlock>[];
  var para = <String>[], quote = <String>[];
  List<String>? list;
  var ordered = false;
  void flush() {
    if (para.isNotEmpty) {
      out.add(XprsMdRawBlock(XprsMdBlockKind.paragraph, para));
      para = [];
    }
    if (list != null) {
      out.add(XprsMdRawBlock(
          ordered ? XprsMdBlockKind.numbers : XprsMdBlockKind.bullets, list!));
      list = null;
    }
    if (quote.isNotEmpty) {
      out.add(XprsMdRawBlock(XprsMdBlockKind.quote, quote));
      quote = [];
    }
  }

  final heading = RegExp(r'^(#{1,3})\s+(.+)$');
  final rule = RegExp(r'^(?:-{3,}|\*{3,}|_{3,})$');
  final quoted = RegExp(r'^>\s?(.*)$');
  final bullet = RegExp(r'^[-*+]\s+(.+)$');
  final number = RegExp(r'^\d{1,3}[.)]\s+(.+)$');
  for (final raw in lines) {
    final l = raw.trim();
    if (l.isEmpty) {
      flush();
      continue;
    }
    var m = heading.firstMatch(l);
    if (m != null) {
      flush();
      out.add(XprsMdRawBlock(XprsMdBlockKind.heading, [m[2]!],
          level: m[1]!.length));
      continue;
    }
    if (rule.hasMatch(l)) {
      flush();
      out.add(const XprsMdRawBlock(XprsMdBlockKind.rule, []));
      continue;
    }
    m = quoted.firstMatch(l);
    if (m != null) {
      if (para.isNotEmpty || list != null) flush();
      quote.add(m[1]!);
      continue;
    }
    m = bullet.firstMatch(l) ?? number.firstMatch(l);
    if (m != null) {
      final num = RegExp(r'^\d').hasMatch(l);
      if (para.isNotEmpty ||
          quote.isNotEmpty ||
          (list != null && ordered != num)) {
        flush();
      }
      if (list == null) {
        list = [];
        ordered = num;
      }
      list!.add(m[1]!);
      continue;
    }
    if (list != null || quote.isNotEmpty) flush();
    para.add(l);
  }
  flush();
  return out;
}

/// The whole text -> HTML.
String xprsMdToHtml(String text, [XprsMdHtml opts = const XprsMdHtml()]) {
  String inl(String t) => xprsMdInlineHtml(t, opts);
  final out = StringBuffer();
  for (final b in xprsMdBlocks(text)) {
    switch (b.kind) {
      case XprsMdBlockKind.paragraph:
        out.write('<p>${b.lines.map(inl).join('<br>')}</p>');
      case XprsMdBlockKind.heading:
        final h = b.level + 2;
        out.write('<h$h>${inl(b.lines.first)}</h$h>');
      case XprsMdBlockKind.rule:
        out.write('<hr>');
      case XprsMdBlockKind.quote:
        out.write('<blockquote>${b.lines.map(inl).join('<br>')}</blockquote>');
      case XprsMdBlockKind.bullets:
      case XprsMdBlockKind.numbers:
        final tag = b.kind == XprsMdBlockKind.numbers ? 'ol' : 'ul';
        out.write('<$tag>${b.lines.map((x) => '<li>${inl(x)}</li>').join()}</$tag>');
    }
  }
  return out.toString();
}

// ---- spans: the same reading, for readers that draw widgets -------------

/// One run of text with one look.
class XprsMdSpan {
  const XprsMdSpan(this.text,
      {this.bold = false,
      this.italic = false,
      this.strike = false,
      this.code = false,
      this.url,
      this.ref,
      this.image = false,
      this.mention});
  final String text;
  final bool bold, italic, strike, code;

  /// An http(s) link this run opens.
  final String? url;

  /// A content reference (7.7 `ref`) this run names: a picture's alt text
  /// ([image]) or a file's label.
  final String? ref;
  final bool image;

  /// The callsign of an @CALL mention ([text] is "@CALL").
  final String? mention;

  bool _sameLook(XprsMdSpan o) =>
      bold == o.bold &&
      italic == o.italic &&
      strike == o.strike &&
      code == o.code &&
      url == o.url &&
      ref == o.ref &&
      image == o.image &&
      mention == o.mention;

  XprsMdSpan withText(String t) => XprsMdSpan(t,
      bold: bold,
      italic: italic,
      strike: strike,
      code: code,
      url: url,
      ref: ref,
      image: image,
      mention: mention);

  @override
  String toString() => [
        text,
        if (bold) 'b',
        if (italic) 'i',
        if (strike) 's',
        if (code) 'c',
        if (url != null) 'u=$url',
        if (ref != null) '${image ? 'img' : 'r'}=$ref',
        if (mention != null) '@=$mention',
      ].join('|');
}

/// A block with its lines read into spans.
class XprsMdBlock {
  const XprsMdBlock(this.kind, this.lines, {this.level = 0});
  final XprsMdBlockKind kind;
  final List<List<XprsMdSpan>> lines;
  final int level;
}

// Markers the span reader asks the HTML reader to write for references and
// mentions; the tag set below is everything xprsMdInlineHtml can produce.
const _spanOpts = XprsMdHtml(
  img: _imgTag,
  file: _fileTag,
  mention: _atTag,
);
String _imgTag(String r, String alt) =>
    '<x-img ref="${xprsMdEscape(r)}">${xprsMdEscape(alt.isEmpty ? r : alt)}</x-img>';
String _fileTag(String r, String label) =>
    '<x-file ref="${xprsMdEscape(r)}">${xprsMdEscape(label)}</x-file>';
String _atTag(String c) => '<x-at>@${xprsMdEscape(c)}</x-at>';

final _tag = RegExp(r'<(/?)(strong|em|del|code|a|x-img|x-file|x-at)(?:\s([^>]*))?>');
final _attr = RegExp(r'(href|ref)="([^"]*)"');

/// One line -> spans: [xprsMdInlineHtml] read back.
List<XprsMdSpan> parseXprsMdInline(String line) {
  final html = xprsMdInlineHtml(line, _spanOpts);
  final out = <XprsMdSpan>[];
  var bold = 0, italic = 0, strike = 0, code = 0;
  String? url, ref, at;
  var image = false;
  void text(String t) {
    if (t.isEmpty) return;
    final s = XprsMdSpan(_unescape(t),
        bold: bold > 0,
        italic: italic > 0,
        strike: strike > 0,
        code: code > 0,
        url: url,
        ref: ref,
        image: image,
        mention: at);
    if (out.isNotEmpty && out.last._sameLook(s)) {
      out[out.length - 1] = out.last.withText(out.last.text + s.text);
    } else {
      out.add(s);
    }
  }

  var pos = 0;
  for (final m in _tag.allMatches(html)) {
    text(html.substring(pos, m.start));
    pos = m.end;
    final close = m[1] == '/';
    final d = close ? -1 : 1;
    final attrs = <String, String>{
      for (final a in _attr.allMatches(m[3] ?? '')) a[1]!: _unescape(a[2]!)
    };
    switch (m[2]) {
      case 'strong':
        bold += d;
      case 'em':
        italic += d;
      case 'del':
        strike += d;
      case 'code':
        code += d;
      case 'a':
        url = close ? null : attrs['href'];
      case 'x-img':
        ref = close ? null : attrs['ref'];
        image = !close;
      case 'x-file':
        ref = close ? null : attrs['ref'];
      case 'x-at':
        at = close ? null : '';
    }
  }
  text(html.substring(pos));
  // A mention's callsign is its text without the @.
  return [
    for (final s in out)
      if (s.mention != null)
        XprsMdSpan(s.text,
            bold: s.bold,
            italic: s.italic,
            strike: s.strike,
            mention: s.text.substring(1))
      else
        s
  ];
}

/// The whole text -> blocks of spans.
List<XprsMdBlock> parseXprsMd(String text) => [
      for (final b in xprsMdBlocks(text))
        XprsMdBlock(b.kind, [for (final l in b.lines) parseXprsMdInline(l)],
            level: b.level)
    ];
