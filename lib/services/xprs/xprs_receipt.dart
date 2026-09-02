/*
 * The receipt: what ends custody (docs/XPRS.md §13.7, §13.7.1).
 *
 * Until this file existed, a held message had no terminal state. Nothing in the
 * app composed a `t:receipt`, so §36.8.1's release rule — "a verified
 * `t:receipt` ends [the retries] and releases the held copy, and every OTHER
 * holder that hears the receipt releases its copy too" — had nothing to fire
 * on. Measured on the bench after a day of carrying:
 *
 *     parked 1739   pending 3699   custodyOut 0   purged 0   delivered 0
 *
 * Every message ever parked was still parked. Not a leak in one place: the
 * store had no way to be told, so it grew to its quota and evicted by urgency,
 * silently dropping the oldest mail of the lowest priority — which is to say,
 * a stranger's, which is the mail custody exists for.
 *
 * ── Why it is signed, and why an unverifiable one changes nothing ───────────
 *
 * §13.7.1 is unusually blunt about this, because `s:ack` is not merely a note
 * to the sender: every carrier holding that message discards its copy on
 * hearing it. So a forged receipt is
 *
 *   "not a lie about delivery -- it is a way to delete a message from the whole
 *    mesh, cheaply, without holding anyone's key, for any callsign the attacker
 *    cares to name. The victim is told their message arrived, the carriers drop
 *    it, and nobody ever finds out."
 *
 * Hence: signed always, and a receipt whose signature does not verify — or
 * whose signer we cannot check — marks nothing, releases nothing, stops
 * nothing. "Unverifiable is not probably fine."
 */
import 'dart:typed_data';

import '../../util/nostr_crypto.dart';
import '../log_service.dart';
import 'xprs_archive.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';

class XprsReceiptCounters {
  /// Receipts we composed and aired.
  static int sent = 0;

  /// Receipts we declined to compose, by reason — each is a §13.7.1 exclusion
  /// rather than a failure, and worth counting apart from an error.
  static int skippedStranger = 0;
  static int skippedNotDirect = 0;

  /// Composed nothing because we hold no signing key. An unsigned receipt is
  /// worse than none (see the header), so this is a refusal, not a fallback.
  static int refusedUnsigned = 0;

  /// Verified receipts heard, and held copies they released.
  static int heard = 0;
  static int released = 0;

  /// Receipts that arrived and could not be trusted: a bad signature, or a
  /// signer whose key we have never heard. Both change nothing.
  static int unverifiable = 0;

  static Map<String, int> get json => {
        'sent': sent,
        'heard': heard,
        'released': released,
        'unverifiable': unverifiable,
        'refusedUnsigned': refusedUnsigned,
        'skippedStranger': skippedStranger,
      };
}

/// Composing and reading `t:receipt … s:ack`.
class XprsReceipt {
  /// The receipt [p] deserves, or null when §13.7.1 says not to send one.
  ///
  /// [p] must be the packet as it arrived: the `r:` value is its §5 identifier,
  /// computed over the wire with `sig:` and `via:` removed, so a relayed copy
  /// and a directly-heard one produce the same receipt.
  /// [state] is `ack` (it reached a device) or `read` (it was opened) —
  /// §13.7's table. `ack` is the core's to send when a message is accepted
  /// for render; `read` is the WAPP's to ask for, because only the thing
  /// drawing the conversation knows a person looked at it.
  static XprsPacket? compose(XprsPacket p,
      {required String selfCallsign,
      BigInt? signingKey,
      String state = 'ack'}) {
    if (p.type != 'message') return null;

    final self = _base(selfCallsign);
    final to = _base(p['d'] ?? '');
    final from = (p['f'] ?? '').trim().toUpperCase();
    if (self.isEmpty || from.isEmpty) return null;

    // §13.7.1's exclusion table, in order. Each of these would put an
    // acknowledgement on a shared channel for every station that hears it.
    //
    //   a broadcast (no `d:`)                 one packet, every hearer answering
    //   a regional message (`dest:`, no `d:`) same, bounded only by the region
    //   a group message                       every member answering every message
    //   a receipt                             never terminates
    if (to.isEmpty || to != self) return null; // not addressed to us
    if (p.has('dest')) {
      XprsReceiptCounters.skippedNotDirect++;
      return null;
    }
    if (!_isStation(p['d'] ?? '')) {
      XprsReceiptCounters.skippedNotDirect++;
      return null;
    }
    if (from == self) return null; // our own echo

    // "A station never exchanged with" — a stranger has agreed to neither the
    // airtime nor the confirmation that this callsign is here and awake.
    if (!XprsArchive.instance.hasExchanged(self, from)) {
      XprsReceiptCounters.skippedStranger++;
      return null;
    }

    final d = signingKey ?? xprsProfileScalar();
    if (d == null) {
      XprsReceiptCounters.refusedUnsigned++;
      LogService.instance.add(
          'XPRS: no receipt for ${xprsIdentifier(p)} — no signing key, and an '
          'unsigned s:ack is a way to delete mail (13.7.1)');
      return null;
    }

    // No `q:` — this is a device reporting bytes, not a person agreeing to
    // anything. That remains `s:sign`, which is still asked for explicitly.
    final r = XprsPacket.parse(
        't:receipt f:$self d:$from r:${xprsIdentifier(p)} ts:${_nowIso()} '
        's:$state');
    if (r == null) return null;
    final signed = xprsSign(r, d);
    return signed.fits ? signed : null;
  }

  /// Read an inbound `t:receipt`. Returns the identifier it releases, or null
  /// when it releases nothing.
  ///
  /// [keyOf] resolves a callsign to its 32-byte x-only public key — the same
  /// resolver the archive verifies with. A signer we cannot check is treated
  /// exactly like a bad signature.
  /// Returns the identifier it releases and WHICH state it reports, or null
  /// when it releases nothing.
  ///
  /// `read` implies `ack`: a message cannot be opened without arriving, and a
  /// peer that only ever sends `read` would otherwise never release custody.
  static ({String id, String state})? release(XprsPacket p,
      {required String selfCallsign, Uint8List? Function(String)? keyOf}) {
    if (p.type != 'receipt') return null;
    final says = (p['s'] ?? '').split(',').map((w) => w.trim()).toSet();
    final read = says.contains('read');
    if (!says.contains('ack') && !read) return null;
    final id = (p['r'] ?? '').trim();
    if (id.length != 6) return null;

    final from = (p['f'] ?? '').trim().toUpperCase();
    if (from.isEmpty || from == _base(selfCallsign)) return null;

    // The whole security of custody release rests on this branch.
    final key = keyOf?.call(from) ?? _resolve(from);
    if (!p.has('sig') || key == null) {
      XprsReceiptCounters.unverifiable++;
      return null;
    }
    if (xprsVerify(p, key) != XprsSigState.verified) {
      XprsReceiptCounters.unverifiable++;
      LogService.instance
          .add('XPRS: receipt for $id from $from does not verify — ignored');
      return null;
    }
    XprsReceiptCounters.heard++;
    return (id: id, state: read ? 'read' : 'ack');
  }

  /// The key the archive already resolves for signature checks. Null when this
  /// station has never heard the signer's `t:identity` — which §13.7.1 treats
  /// exactly like a bad signature.
  static Uint8List? _resolve(String call) {
    try {
      return XprsArchive.instance.keyResolver?.call(call);
    } catch (_) {
      return null;
    }
  }

  static String _base(String c) => NostrCrypto.bareCallsign(c).toUpperCase();

  /// A station address, not a group (§6.3) — the same test the funnel uses to
  /// decide what is custody material.
  static bool _isStation(String d) {
    final s = d.trim().toUpperCase();
    if (s.isEmpty || s.startsWith('#') || s.startsWith('!')) return false;
    return RegExp(r'^(X[1345][A-Z0-9]{2,5}|[A-Z0-9]{1,3}[0-9][A-Z0-9]*)'
            r'(-[0-9]{1,2})?(/[A-Z0-9]+)?$')
        .hasMatch(s);
  }

  static String _nowIso() {
    final t = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}_'
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
