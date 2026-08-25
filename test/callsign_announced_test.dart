// A node's callsign is its own choice of prefix and length (spec section 3),
// and the observer's job is to CHECK it, not to invent a second name for it.
// Before this, rns_service derived X1+4 and let it OVERRIDE the announcement,
// so a station calling itself X3ARK appeared to the whole mesh as X1ARKL.
import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/reticulum.dart';

void main() {
  const npub =
      'npub1arklg83wnqy4s6stnl65hl9dt980xfgsh6vxz8jeg7r2a9hwta6s3zd263';
  final hex = NostrCrypto.decodeNpub(npub);

  test('a station callsign is as self-certifying as an operator one', () {
    expect(NostrKeyGenerator.deriveStationCallsign(npub, length: 3), 'X3ARK');
    expect(NostrCrypto.callsignMatchesKey('X3ARK', hex), isTrue);
    // The same key's X1 name at the default length is equally valid — which is
    // exactly why the observer must not pick one and overwrite the other.
    expect(NostrKeyGenerator.deriveCallsign(npub), 'X1ARKL');
    expect(NostrCrypto.callsignMatchesKey('X1ARKL', hex), isTrue);
    // A device suffix does not break the check (section 3.1).
    expect(NostrCrypto.callsignMatchesKey('X3ARK-2', hex), isTrue);
  });

  test('a name the key cannot produce is refused', () {
    expect(NostrCrypto.callsignMatchesKey('X3ZZZ', hex), isFalse);
    // An issued callsign has no arithmetic relation to a key (section 9.4.2),
    // so it fails this test and the observer falls back to the derived name
    // rather than repeating a claim it cannot check.
    expect(NostrCrypto.callsignMatchesKey('CT1ABC', hex), isFalse);
  });
}
