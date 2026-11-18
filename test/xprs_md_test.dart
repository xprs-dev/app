// Formatted text (XPRS.md 4.11) as the chat bubble reads it: lib/util/xprs_md.dart
// (a port of the web chat's page/xprs_md.js) and the widget that draws it with
// tappable links (lib/wapp/geoui/widgets/xprs_md_text.dart).
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/util/xprs_md.dart';
import 'package:xprs/wapp/geoui/widgets/xprs_md_text.dart';

List<String> line(String s) =>
    [for (final x in parseXprsMdInline(s)) x.toString()];

void main() {
  test('a bare link is a link, without the sentence end', () {
    expect(line('see https://xprs.dev/in/X1QZ3N.'),
        ['see ', 'https://xprs.dev/in/X1QZ3N|u=https://xprs.dev/in/X1QZ3N', '.']);
  });

  test('a named link keeps its words; other schemes stay text', () {
    expect(line('[the spec](https://xprs.dev/spec) and [x](javascript:alert)'), [
      'the spec|u=https://xprs.dev/spec',
      ' and [x](javascript:alert)',
    ]);
  });

  test('emphasis, strike and code', () {
    expect(line('**bold** *it* _it_ ~~gone~~ `a*b*c`'), [
      'bold|b',
      ' ',
      'it|i',
      ' ',
      'it|i',
      ' ',
      'gone|s',
      ' ',
      'a*b*c|c',
    ]);
  });

  test('snake_case and a link with underscores are not italic', () {
    expect(line('snake_case_name'), ['snake_case_name']);
    expect(line('_go_ https://a.org/x_y_z'),
        ['go|i', ' ', 'https://a.org/x_y_z|u=https://a.org/x_y_z']);
  });

  test('a link inside bold is bold and a link', () {
    expect(line('**https://a.org**'), ['https://a.org|b|u=https://a.org']);
  });

  test('blocks: heading, list, quote, rule, paragraphs by U+2029', () {
    final b = parseXprsMd(
        '## Title - one - two > said --- end line');
    expect(b.map((x) => x.kind), [
      XprsMdBlockKind.heading,
      XprsMdBlockKind.bullets,
      XprsMdBlockKind.quote,
      XprsMdBlockKind.rule,
      XprsMdBlockKind.paragraph,
    ]);
    expect(b.first.level, 2);
    expect(b[1].lines, hasLength(2));
    expect(b.last.lines, hasLength(2));
  });

  test('plain words need no formatting', () {
    expect(xprsMdHasMarkup('hello there, all good?'), isFalse);
    expect(xprsMdHasMarkup('look at http://example.com'), isTrue);
    expect(xprsMdHasMarkup('**hi**'), isTrue);
  });

  testWidgets('tapping a link in the text opens it', (tester) async {
    String? opened;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: XprsMdText('go to https://xprs.dev now',
            style: const TextStyle(fontSize: 14, color: Colors.white),
            linkColor: Colors.blue,
            mutedColor: Colors.grey,
            onLink: (u) => opened = u),
      ),
    ));
    final rich = tester.widget<RichText>(find.byType(RichText).first);
    TextSpan? link;
    rich.text.visitChildren((s) {
      if (s is TextSpan && s.recognizer != null) link = s;
      return true;
    });
    expect(link?.text, 'https://xprs.dev');
    (link!.recognizer! as TapGestureRecognizer).onTap!();
    expect(opened, 'https://xprs.dev');
  });
}
