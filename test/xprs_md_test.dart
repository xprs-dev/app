// The app's formatted-text reader (lib/util/xprs_md.dart) against its cases
// (test/xprs_md_cases.json), plus the span view XprsMdText draws from.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/util/xprs_md.dart';

String _esc(String s, {bool quote = false}) {
  var r = s.replaceAll('&', '&amp;');
  if (quote) r = r.replaceAll('"', '&quot;');
  return r.replaceAll('<', '&lt;');
}

final _opts = XprsMdHtml(
  img: (r, a) => '<img src="$r" alt="${_esc(a, quote: true)}">',
  file: (r, l) => '<a data-ref="$r">${_esc(l)}</a>',
  mention: (c) => '<span class="at">@$c</span>',
);

List<String> line(String s) =>
    [for (final x in parseXprsMdInline(s)) x.toString()];

void main() {
  final doc = jsonDecode(File('test/xprs_md_cases.json').readAsStringSync())
      as Map<String, dynamic>;
  group('cases', () {
    for (final v in (doc['vectors'] as List).cast<Map<String, dynamic>>()) {
      test(v['name'], () {
        expect(xprsMdToHtml(v['input'] as String, _opts), v['html']);
        expect(xprsMdToHtml(v['input'] as String), v['plain']);
      });
    }
  });

  test('spans: links, emphasis, code', () {
    expect(line('see https://xprs.dev.'),
        ['see ', 'https://xprs.dev|u=https://xprs.dev', '.']);
    expect(line('**https://a.org**'), ['https://a.org|b|u=https://a.org']);
    expect(line('*a **b** c*'), ['a |i', 'b|b|i', ' c|i']);
    expect(line('`<b>` & x'), ['<b>|c', ' & x']);
  });

  test('spans: mentions and references', () {
    expect(line('hi @X1QZ3N'), ['hi ', '@X1QZ3N|@=X1QZ3N']);
    const r = 'nYxKzGm4vT2pQ8dW5jR7cL0aFbNs9hUe3oXiC6EkM1w';
    expect(line('![pic]($r.jpg) [doc]($r.pdf)'),
        ['pic|img=$r.jpg', ' ', 'doc|r=$r.pdf']);
  });

  test('blocks', () {
    final b = parseXprsMd('## T - a - b > q --- x');
    expect(b.map((x) => x.kind), [
      XprsMdBlockKind.heading,
      XprsMdBlockKind.bullets,
      XprsMdBlockKind.quote,
      XprsMdBlockKind.rule,
      XprsMdBlockKind.paragraph,
    ]);
    expect(b.first.level, 2);
  });

  test('wire round trip', () {
    const typed = 'one\ntwo\n\nthree';
    expect(xprsMdToWire(typed), 'one two three');
    expect(xprsMdFromWire(xprsMdToWire(typed)), typed);
    expect(xprsMdHasMarkup('plain words only'), isFalse);
    expect(xprsMdHasMarkup('go https://a.org'), isTrue);
  });
}
