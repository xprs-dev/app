// A link shared with its card (lib/wapp/link_cards.dart, XPRS.md 7.7.7):
// the link a sentence carries, and the page's title and summary written as a
// plain line that never grows the message past what it may carry.
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/link_cards.dart';

void main() {
  test('the first link, without the punctuation after it', () {
    expect(LinkCards.firstUrl('see https://example.com/a/b. ok'),
        'https://example.com/a/b');
    expect(LinkCards.firstUrl('(https://en.wikipedia.org/wiki/Foo_(bar))'),
        'https://en.wikipedia.org/wiki/Foo_(bar)');
    expect(LinkCards.firstUrl('two: http://a.example/x and https://b.example'),
        'http://a.example/x');
    expect(LinkCards.firstUrl('no link here'), isNull);
    expect(LinkCards.firstUrl('ftp://example.com/file'), isNull);
  });

  test('the title and summary are a plain line after the words', () {
    const card = LinkCard(
        url: 'https://example.com/a',
        title: 'Antenna survives',
        summary: 'A dipole on the ridge.',
        site: 'example.com');
    expect(LinkCards.withCard('look https://example.com/a', card),
        'look https://example.com/a\u2028Antenna survives — A dipole on the ridge.');
  });

  test("the page's own line breaks become spaces", () {
    const card = LinkCard(
        url: 'https://example.com/a',
        title: 'Title',
        summary: 'line one\nline two',
        site: 'example.com');
    expect(LinkCards.withCard('x', card), 'x\u2028Title — line one line two');
  });

  test('a long summary is cut to fit, a message too long goes alone', () {
    final card = LinkCard(
        url: 'https://example.com/a',
        title: 'Title',
        summary: List.filled(60, 'word').join(' '),
        site: 'example.com');
    final out = LinkCards.withCard('hi', card);
    final quote = out.substring(out.indexOf('\u2028') + 1);
    expect(quote.length, lessThanOrEqualTo(LinkCards.maxCardChars));
    expect(quote, endsWith('…'));
    final long = 'x' * (LinkCards.maxMessageChars - 10);
    expect(LinkCards.withCard(long, card), long);
  });

  test('an answer with neither title nor summary is no card', () {
    expect(LinkCard.fromResult({'url': 'u', 'title': '', 'summary': ''}), isNull);
    final c = LinkCard.fromResult(
        {'url': 'u', 'title': 'T', 'summary': '', 'site': 's', 'file': 'nope'});
    expect(c?.token, isNull);
    expect(LinkCard.fromResult({'title': 'T', 'file': 'file:abc.jpg'})?.token,
        'file:abc.jpg');
  });
}
