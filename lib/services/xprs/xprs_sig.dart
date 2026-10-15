/// Signing and verifying an XPRS packet.
///
/// `docs/XPRS.md` section 9.1: `sig:` covers the whole packet with the `sig:`
/// and `via:` fields removed, so position is not significant and a verifier
/// reconstructs the signed text by deletion.
///
/// That is the same canonical form the identifier is derived from (section 5),
/// which is not a coincidence: both have to survive relaying, and relaying only
/// ever touches `via:`.
///
/// The crypto is [XprsCrypto], unchanged. Its 48-byte short-Schnorr signature
/// encodes to exactly 60 base85 characters, which is what the XPRS `base85`
/// value type is (section 4.3) — so this file is a shim over a primitive that
/// already shipped, not a new implementation.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:hex/hex.dart';

import '../../profile/profile_service.dart';
import '../../util/xprs_crypto.dart';
import '../../util/nostr_crypto.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_vocab.dart' show xprsParseTs;

/// How a receiver should present the authorship of a packet (section 9.1).
enum XprsSigState {
  /// Signature present, valid, and the signer's key is known.
  verified,

  /// Signature present and invalid. The only state that is evidence of a lie.
  forged,

  /// Signature present but the signer's key is not held, so it cannot be checked.
  unverified,

  /// No signature. Common and legitimate: sensors and small stations do not sign.
  unsigned,
}

/// The canonical text a signature covers: the packet without `sig:` or `via:`.
///
/// Public because a verifier has to reconstruct it, and because disagreeing
/// about it is the kind of bug that only surfaces between two independent
/// implementations — by which time both are deployed.
String xprsSignedText(XprsPacket p) => p.without(kIdExcluded).encode();

/// The digest actually passed to the curve: sha256 of [xprsSignedText].
Uint8List xprsSignedDigest(XprsPacket p) =>
    NostrCrypto.sha256Bytes(Uint8List.fromList(utf8.encode(xprsSignedText(p))));

/// Sign [p] with the private scalar [d], returning the packet with `sig:` set.
///
/// `sig:` is inserted before `m:` when the packet has one, because `m:` must
/// stay last (section 4) — [XprsPacket.with_] already does that.
XprsPacket xprsSign(XprsPacket p, BigInt d) =>
    p.with_('sig', XprsCrypto.b85encode(XprsCrypto.sign(xprsSignedDigest(p), d)));

/// The NOSTR event kind XPRS.md 6.1.3 gives to a packet signature.
const int kXprsNostrKind = 24767;

/// The id of the NOSTR event a 6.1.3 signature is over, rebuilt from the
/// packet: `[0, "<px>", <ts as epoch seconds>, 24767, [], "<digest hex>"]`
/// hashed with sha256. Null when the packet has no usable `ts:`, because this
/// form needs a time and a packet without one cannot use it.
Uint8List? xprsNostrEventId(XprsPacket p, Uint8List pubXonly) {
  final ms = xprsParseTs(p['ts']);
  if (ms == null) return null;
  final event = jsonEncode([
    0,
    HEX.encode(pubXonly),
    ms ~/ 1000,
    kXprsNostrKind,
    <Object>[],
    HEX.encode(xprsSignedDigest(p)),
  ]);
  return NostrCrypto.sha256Bytes(Uint8List.fromList(utf8.encode(event)));
}

/// Sign [p] in the second form (6.1.3) with [d]: what a NOSTR signer produces
/// for it. For tests and tools; a station that holds its key signs with
/// [xprsSign], and a browser extension makes this one itself.
XprsPacket xprsSignNostr(XprsPacket p, BigInt d, {Uint8List? aux}) {
  final id = xprsNostrEventId(p, XprsCrypto.publicKeyXOnly(d));
  if (id == null) return p;
  return p.with_('sig', XprsCrypto.b85encode(XprsCrypto.bip340Sign(id, d, aux: aux)));
}

/// The private scalar XPRS signs with: the active profile's nsec, decoded.
///
/// Null when there is no profile or the nsec does not decode — the caller
/// then transmits unsigned, which the spec permits (section 9.1). ONE
/// implementation of "which key signs XPRS": the courier and the publisher
/// both come here.
BigInt? xprsProfileScalar() {
  final nsec = ProfileService.instance.activeProfile?.nsec ?? '';
  if (nsec.isEmpty) return null;
  try {
    var d = BigInt.zero;
    for (final b in HEX.decode(NostrCrypto.decodeNsec(nsec))) {
      d = (d << 8) | BigInt.from(b);
    }
    return d;
  } catch (_) {
    return null;
  }
}

/// Check the `sig:` on [p] against [pubXonly], the signer's 32-byte x-only key.
///
/// Pass a null key for a signer whose key is not held: the result is
/// [XprsSigState.unverified] rather than a guess.
XprsSigState xprsVerify(XprsPacket p, Uint8List? pubXonly) {
  final s = p['sig'];
  if (s == null) return XprsSigState.unsigned;
  if (pubXonly == null) return XprsSigState.unverified;

  // Two forms, told apart by length (6.1.3): 60 characters, the short Schnorr
  // of 6.1.2, and 80, a BIP-340 signature over a NOSTR event. Any other length
  // is not a signature.
  final sig = XprsCrypto.b85decode(s);
  if (sig == null || (sig.length != 48 && sig.length != 64)) {
    return XprsSigState.forged;
  }

  // One packet is checked by the archive, by the ingest and by the delivery
  // to wapps, and again for every copy that arrives over another bearer or
  // relayed: each check was a curve operation in pure Dart on the UI
  // isolate. The verdict for these exact bytes under this key does not
  // change, so it is worked out once (docs/performance.md 3.2 and 8.12).
  final digest = xprsSignedDigest(p);
  final memo = '${HEX.encode(digest)}|$s|${HEX.encode(pubXonly)}';
  final known = _verdicts.remove(memo);
  if (known != null) {
    _verdicts[memo] = known;
    return known;
  }
  final bool good;
  if (sig.length == 48) {
    good = XprsCrypto.verify(digest, sig, pubXonly);
  } else {
    final id = xprsNostrEventId(p, pubXonly);
    good = id != null && XprsCrypto.bip340Verify(id, sig, pubXonly);
  }
  final state = good ? XprsSigState.verified : XprsSigState.forged;
  if (_verdicts.length >= 512) _verdicts.remove(_verdicts.keys.first);
  _verdicts[memo] = state;
  return state;
}

final Map<String, XprsSigState> _verdicts = {};
