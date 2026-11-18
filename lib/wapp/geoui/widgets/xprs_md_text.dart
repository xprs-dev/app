// Draws formatted text (XPRS.md 4.11, read by core xprs_md.dart) as ONE
// Text.rich, so it shrink-wraps inside a chat bubble's IntrinsicWidth like the
// plain Text it replaces. Links (written [words](https://...) or bare) open in
// the system browser on tap; everything else is styling.
//
// Cost: the text is parsed once per change of [text], not per frame; the tap
// recognizers are rebuilt with the spans and disposed with them.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:xprs_core/src/util/xprs_md.dart';

/// Open an http(s) link outside the app. False when nothing could open it.
Future<bool> openExternalLink(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) {
    return false;
  }
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}

class XprsMdText extends StatefulWidget {
  const XprsMdText(
    this.text, {
    super.key,
    required this.style,
    required this.linkColor,
    required this.mutedColor,
    this.codeBackground = const Color(0x33FFFFFF),
    this.onLink,
    this.maxLines,
  });

  final String text;
  final TextStyle style;
  final Color linkColor;

  /// Quotes, rules and references.
  final Color mutedColor;
  final Color codeBackground;

  /// What a tapped link does; null opens it with [openExternalLink].
  final void Function(String url)? onLink;

  /// Cut after this many lines with an ellipsis (a card's preview); null: all.
  final int? maxLines;

  @override
  State<XprsMdText> createState() => _XprsMdTextState();
}

class _XprsMdTextState extends State<XprsMdText> {
  late List<XprsMdBlock> _blocks = parseXprsMd(widget.text);
  final List<TapGestureRecognizer> _taps = [];

  @override
  void didUpdateWidget(XprsMdText old) {
    super.didUpdateWidget(old);
    if (old.text != widget.text) _blocks = parseXprsMd(widget.text);
  }

  @override
  void dispose() {
    _dropTaps();
    super.dispose();
  }

  void _dropTaps() {
    for (final t in _taps) {
      t.dispose();
    }
    _taps.clear();
  }

  void _open(String url) {
    final f = widget.onLink;
    if (f != null) {
      f(url);
    } else {
      openExternalLink(url).then((ok) {
        if (!ok && mounted) {
          ScaffoldMessenger.maybeOf(context)
              ?.showSnackBar(SnackBar(content: Text(url)));
        }
      });
    }
  }

  TextSpan _span(XprsMdSpan s, TextStyle base) {
    var st = base;
    if (s.bold) st = st.copyWith(fontWeight: FontWeight.w700);
    if (s.italic) st = st.copyWith(fontStyle: FontStyle.italic);
    if (s.code) {
      st = st.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: const ['Courier New', 'Courier'],
          backgroundColor: widget.codeBackground);
    }
    final url = s.url;
    if (url != null) {
      st = st.copyWith(
          color: widget.linkColor,
          decoration: TextDecoration.underline,
          decorationColor: widget.linkColor);
      final tap = TapGestureRecognizer()..onTap = () => _open(url);
      _taps.add(tap);
      return TextSpan(text: s.text, style: st, recognizer: tap);
    }
    if (s.mention != null) {
      st = st.copyWith(fontWeight: FontWeight.w600);
    }
    if (s.ref != null) {
      st = st.copyWith(color: widget.mutedColor, fontStyle: FontStyle.italic);
    }
    if (s.strike) {
      st = st.copyWith(
          decoration: TextDecoration.combine([
        if (st.decoration != null) st.decoration!,
        TextDecoration.lineThrough,
      ]));
    }
    return TextSpan(text: s.text, style: st);
  }

  @override
  Widget build(BuildContext context) {
    _dropTaps();
    final base = widget.style;
    final size = base.fontSize ?? 14;
    final muted = base.copyWith(color: widget.mutedColor);
    final children = <InlineSpan>[];
    void lineBreak() => children.add(const TextSpan(text: '\n'));
    for (var b = 0; b < _blocks.length; b++) {
      final block = _blocks[b];
      if (b > 0) {
        // A paragraph gap: the end of the last line, then a half-height line.
        lineBreak();
        children.add(TextSpan(
            text: '\n', style: base.copyWith(fontSize: size * 0.45)));
      }
      void line(List<XprsMdSpan> spans, TextStyle st) {
        for (final s in spans) {
          children.add(_span(s, st));
        }
      }

      switch (block.kind) {
        case XprsMdBlockKind.rule:
          children.add(TextSpan(text: '—' * 8, style: muted));
        case XprsMdBlockKind.heading:
          final scale = const [1.0, 1.35, 1.2, 1.08][block.level.clamp(1, 3)];
          line(
              block.lines.first,
              base.copyWith(
                  fontSize: size * scale, fontWeight: FontWeight.w700));
        case XprsMdBlockKind.paragraph:
        case XprsMdBlockKind.quote:
        case XprsMdBlockKind.bullets:
        case XprsMdBlockKind.numbers:
          for (var i = 0; i < block.lines.length; i++) {
            if (i > 0) lineBreak();
            switch (block.kind) {
              case XprsMdBlockKind.quote:
                children.add(TextSpan(
                    text: '▎ ',
                    style: base.copyWith(color: widget.linkColor)));
                line(block.lines[i], muted);
              case XprsMdBlockKind.bullets:
                children.add(TextSpan(text: '• ', style: muted));
                line(block.lines[i], base);
              case XprsMdBlockKind.numbers:
                children.add(TextSpan(text: '${i + 1}. ', style: muted));
                line(block.lines[i], base);
              default:
                line(block.lines[i], base);
            }
          }
      }
    }
    return Text.rich(TextSpan(style: base, children: children),
        maxLines: widget.maxLines,
        overflow: widget.maxLines == null ? null : TextOverflow.ellipsis);
  }
}
