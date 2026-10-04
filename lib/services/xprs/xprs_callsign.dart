/*
 * xprs_callsign — the shape of a callsign, decided once.
 *
 * Four places asked "is this string a callsign" and each answered differently:
 * `_shaped` in xprs_presence (which had no `/`, so `G0XYZ/P` was nameless),
 * `xprsAddressesStation` in xprs_vocab (which had one), `_isStation` in
 * xprs_receipt (a third spelling), and `_looksLikeStation` in xprs_catchup
 * (which tested two prefixes and so never asked a licensed archiver anything).
 * This is the one grammar they share.
 *
 * It also answers the question a licensed operator's profile screen has to ask
 * before it saves anything: could a radio authority have issued this? XPRS.md
 * 6.4.2 is blunt that no part of this format can tell whether a callsign was
 * issued to the person typing it, so the most this file does is reject what
 * certainly was not: a name this app's own key generated, a node number of
 * another network, and a string that is not callsign-shaped at all.
 *
 * The grammar is XPRS.md 670 (the `call` value type: uppercase letters,
 * digits, `-` and `/`) and XPRS.md 228-235 ("Callsigns are always uppercase
 * and are not a fixed length... Nothing in this format assumes a callsign
 * length"). So recognition keeps an unbounded tail, and the length ceiling
 * below is this implementation's reach, not a rule about callsigns.
 *
 * Pure on purpose, and with ZERO imports, for the same reason
 * xprs_presence.dart is pure (docs/architecture.md section 3): it is read by
 * the receive funnel, by the profile screen in lib/profile, and by the packet
 * vocabulary. Importing xprs_packet here would drag the codec into all three.
 */
library;

/// How long a callsign this implementation carries end to end.
///
/// Set by the narrowest hop, which is the wapp HAL: the chat wapp reads
/// `hal_identity` into `char id[16]` and asks for `sizeof(id) - 1`
/// (`../apps/chat/main.c:979`). The MSP custody protocol was the other
/// ceiling at nine, and `mesh_session.dart` now carries this instead.
///
/// This is a limit of the software, not of the format: XPRS.md 228-235 is
/// explicit that nothing in the format assumes a length.
const int kXprsMaxCallsignChars = 15;

/// Anything this format could carry in `f:` or `d:`: an `X1` to `X5` callsign
/// this app's own keys derive, or one an authority issued, either with an
/// optional device suffix (XPRS.md 3.1) and an optional `/` suffix.
///
/// Deliberately generous, and deliberately unbounded in its tail. This is
/// recognition, which must not refuse a longer callsign than we have met
/// before; [xprsIssuedCallsignRefusal] is the strict side.
final RegExp _shape = RegExp(
  r'^(X[1-5][A-Z0-9]{2,5}'
  r'|[A-Z0-9]{1,3}[0-9][A-Z0-9]*)'
  r'(-[0-9]{1,2})?(/[A-Z0-9]{1,4})?$',
);

/// The charset of the `call` value type (XPRS.md 670), and nothing else.
final RegExp _charset = RegExp(r'^[A-Z0-9/-]+$');

/// A node number of another network (XPRS.md 3.2): the two letters and exactly
/// eight uppercase hexadecimal digits, matched WHOLE and with no suffix,
/// exactly as `xprsNetworkOf` does. No key derives it and nobody can sign as
/// it, so it is never a callsign an operator may claim.
final RegExp _foreign = RegExp(r'^M[TC][0-9A-F]{8}$');

/// The body every amateur callsign has: a prefix, a separating numeral, then a
/// letter suffix. Used only for the SOFT warning, because XPRS.md 228-235
/// forbids making a shape rule binding.
final RegExp _issuedBody = RegExp(
  r'^[A-Z0-9]{1,3}[0-9][A-Z]{1,4}'
  r'(-[0-9]{1,2})?(/[A-Z0-9]{1,4})?$',
);

/// Trimmed and uppercase, which is what a callsign always is (XPRS.md 228).
///
/// Every predicate here normalises first, so a caller never has to, and a
/// lowercase string is refused for what it says rather than for its case.
String xprsNormaliseCallsign(String s) => s.trim().toUpperCase();

/// Could this string be a callsign at all? The one shape test.
bool xprsIsCallsignShaped(String s) =>
    _shape.hasMatch(xprsNormaliseCallsign(s));

/// Is this a callsign a holder derived from their own key (XPRS.md 3)?
///
/// `X1` to `X5`, which no authority issues and no register lists. A packet
/// whose `f:` is one of these must never be originated onto a licensed
/// frequency (XPRS.md 6.4.1).
bool xprsIsSelfGenerated(String s) {
  final c = xprsNormaliseCallsign(s);
  return c.length >= 3 &&
      c.codeUnitAt(0) == 0x58 /* X */ &&
      c.codeUnitAt(1) >= 0x31 /* 1 */ &&
      c.codeUnitAt(1) <= 0x35 /* 5 */ &&
      _shape.hasMatch(c);
}

/// A node of another network (XPRS.md 3.2), which is nobody's licence.
bool xprsIsForeignNodeNumber(String s) =>
    _foreign.hasMatch(xprsNormaliseCallsign(s));

/// Does this read like a callsign an authority issues: prefix, numeral,
/// letters? True for `CT1ABC`, `G0XYZ/P`, `2E0ABC`, `4U1ITU`, `W1AW`.
///
/// False is a WARNING and never a refusal. XPRS.md 228-235 says nothing in
/// this format assumes a callsign length, and callsign plans differ by
/// administration, so a shape this file has not met is still allowed through
/// with a word of doubt beside it.
bool xprsLooksIssued(String s) {
  final c = xprsNormaliseCallsign(s);
  return !xprsIsSelfGenerated(c) &&
      !_foreign.hasMatch(c) &&
      _issuedBody.hasMatch(c);
}

/// Null when [s] may be saved as this operator's licensed callsign, else one
/// sentence fit to put in front of them.
///
/// What this CANNOT check, and what the profile screen therefore has to say
/// out loud: whether the callsign was issued to this person. XPRS.md 6.4.2 is
/// explicit that an issued callsign "has no arithmetic relationship to any
/// key, and this format has no registry and issues no credentials". Only the
/// authority's own public register answers that, out of band and once.
String? xprsIssuedCallsignRefusal(String s) {
  final c = xprsNormaliseCallsign(s);
  if (c.isEmpty) return 'Enter the callsign on your licence.';
  if (!_charset.hasMatch(c)) {
    return 'A callsign holds only letters, digits, a hyphen and a slash '
        '(no spaces or punctuation).';
  }
  if (c.length > kXprsMaxCallsignChars) {
    return 'At most $kXprsMaxCallsignChars characters: this is what every '
        'hop in XPRS carries without shortening it.';
  }
  if (xprsIsSelfGenerated(c)) {
    return '$c is a callsign your own key generated, not one an authority '
        'issued. It stays yours either way.';
  }
  if (_foreign.hasMatch(c)) {
    return '$c is a node number from another network, not a callsign.';
  }
  final hyphens = c.split('-').length - 1;
  final slashes = c.split('/').length - 1;
  if (hyphens > 1) {
    return 'Only one hyphen, naming one device (for example CT1ABC-9).';
  }
  if (slashes > 1) {
    return 'Only one slash (for example G0XYZ/P).';
  }
  if (c.startsWith('-') || c.startsWith('/')) {
    return 'A callsign starts with a letter or a digit.';
  }
  if (c.endsWith('-') || c.endsWith('/')) {
    return 'Finish the suffix, or remove it.';
  }
  if (hyphens == 1) {
    final ssid = int.tryParse(c.split('-')[1].split('/')[0]);
    if (ssid == null || ssid < 1 || ssid > 99) {
      return 'A device number runs from 1 to 99 (for example CT1ABC-9).';
    }
  }
  if (!RegExp(r'[0-9]').hasMatch(c)) {
    return 'A callsign has a digit in it. $c reads as a group name.';
  }
  if (!RegExp(r'[A-Z]').hasMatch(c)) {
    return 'A callsign has a letter in it.';
  }
  if (!_shape.hasMatch(c)) {
    return '$c is not shaped like a callsign.';
  }
  return null;
}
