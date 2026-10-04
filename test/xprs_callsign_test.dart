// The shape of a callsign, decided once (lib/services/xprs/xprs_callsign.dart).
//
// Four files used to answer "is this a callsign" four ways, and the cheapest
// way to keep one answer honest is to write the whole table down. The accept
// list is real amateur callsigns from several administrations, because a
// grammar tuned to CT1ABC alone would refuse most of the world.
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/xprs/xprs_callsign.dart';

void main() {
  group('a callsign an authority could have issued', () {
    // Prefix, separating numeral, letter suffix, from several callsign plans:
    // a two-letter prefix (CT1ABC), one letter (G0XYZ), a digit-letter prefix
    // (2E0ABC), a three-character prefix (3DA0ABC), a short special event
    // (K2A) and an ITU station (4U1ITU).
    const good = [
      'CT1ABC', 'G0XYZ', '2E0ABC', '9A1AA', '3DA0ABC', '1A0KM',
      'W1AW', 'K2A', '4U1ITU',
      'CT1ABC-9', 'CT1ABC-1', 'CT1ABC-99', // a device suffix (XPRS.md 3.1)
      'G0XYZ/P', 'CT1ABC/M', 'CT1ABC-9/P', // a slash suffix (XPRS.md 670)
    ];

    for (final c in good) {
      test('$c is accepted', () {
        expect(xprsIssuedCallsignRefusal(c), isNull);
        expect(xprsIsCallsignShaped(c), isTrue);
        expect(xprsLooksIssued(c), isTrue, reason: 'no soft warning for $c');
        expect(xprsIsSelfGenerated(c), isFalse);
      });
    }

    test('lowercase is normalised, not refused for its case', () {
      expect(xprsNormaliseCallsign('  ct1abc  '), 'CT1ABC');
      expect(xprsIssuedCallsignRefusal('ct1abc'), isNull);
      expect(xprsIsCallsignShaped('ct1abc'), isTrue);
    });
  });

  group('refused, each for its own reason', () {
    void refuses(String c, String because) {
      test('$c: $because', () {
        final why = xprsIssuedCallsignRefusal(c);
        expect(why, isNotNull, reason: '$c should be refused');
        expect(why, contains(because));
      });
    }

    refuses('', 'licence');
    refuses('CT1 ABC', 'no spaces');
    refuses('CT1ABC!', 'no spaces'); // the charset message covers punctuation
    refuses('CT1.ABC', 'no spaces');
    // A name this app's own key generated (XPRS.md 3). Every prefix.
    refuses('X1ABCD', 'your own key generated');
    refuses('X2ABCD', 'your own key generated');
    refuses('X3ARK', 'your own key generated');
    refuses('X4PL3M', 'your own key generated');
    refuses('X5A3F2', 'your own key generated');
    // A node number of another network (XPRS.md 3.2).
    refuses('MT0C39F654', 'another network');
    refuses('MC00C0FFEE', 'another network');
    refuses('CT1ABC-9-2', 'Only one hyphen');
    refuses('CT1ABC/P/M', 'Only one slash');
    refuses('-CT1ABC', 'starts with');
    refuses('/CT1ABC', 'starts with');
    refuses('CT1ABC-', 'Finish the suffix');
    refuses('CT1ABC/', 'Finish the suffix');
    refuses('CT1ABC-0', 'runs from 1 to 99');
    refuses('CT1ABC-100', 'runs from 1 to 99');
    refuses('LISBOA', 'reads as a group name');
    refuses('NEWS', 'reads as a group name');
    refuses('123456', 'has a letter in it');
    refuses('ROOM7', 'not shaped like a callsign');
    refuses('ABCDEFGHIJKLMNOP', 'At most 15'); // 16 characters

    test('an X callsign is refused whatever its case or suffix', () {
      expect(xprsIssuedCallsignRefusal('x1abcd'), isNotNull);
      expect(xprsIssuedCallsignRefusal('X1ABCD-2'), isNotNull);
      expect(xprsIsSelfGenerated('X1ABCD-2'), isTrue);
    });
  });

  group('the shape test the four regexes fold into', () {
    test('a slash suffix is recognised, which _shaped used to miss', () {
      // xprs_presence._shaped had no `/` group, so a station announcing
      // G0XYZ/P fell off paths 3, 4, 4b and 5 of `_name` and went unnamed.
      expect(xprsIsCallsignShaped('G0XYZ/P'), isTrue);
      expect(xprsIsCallsignShaped('X1ABCD-2/P'), isTrue);
    });

    test('an X callsign is shaped, and so is a licensed one', () {
      expect(xprsIsCallsignShaped('X1ABCD'), isTrue);
      expect(xprsIsCallsignShaped('X5A3F2'), isTrue);
      expect(xprsIsCallsignShaped('CT1ABC-9'), isTrue);
    });

    test('an open group name is not shaped', () {
      expect(xprsIsCallsignShaped('LISBOA'), isFalse);
      expect(xprsIsCallsignShaped('NEWS'), isFalse);
      expect(xprsIsCallsignShaped(''), isFalse);
    });

    test('a foreign node number is shaped but is nobody\'s licence', () {
      // It has the shape of an amateur callsign, which is exactly the trap
      // docs/meshtastic.md warns about. Recognition says yes; the operator
      // entry point says no.
      expect(xprsIsCallsignShaped('MT0C39F654'), isTrue);
      expect(xprsIsForeignNodeNumber('MT0C39F654'), isTrue);
      expect(xprsLooksIssued('MT0C39F654'), isFalse);
    });
  });

  group('the soft warning, which is never a refusal', () {
    test('a shaped callsign with no letter suffix is allowed with doubt', () {
      // XPRS.md 228-235 forbids making a shape rule binding, so a string this
      // file has not met still saves, with a word of doubt beside it.
      expect(xprsIssuedCallsignRefusal('NET21'), isNull);
      expect(xprsLooksIssued('NET21'), isFalse);
    });
  });

  test('the ceiling is the narrowest hop, not a rule about callsigns', () {
    // ../apps/chat/main.c:979 reads hal_identity into char id[16].
    expect(kXprsMaxCallsignChars, 15);
    expect(xprsIssuedCallsignRefusal('CT1ABC-9/PORT'), isNull); // 13
  });
}
