/*
 * xprs_send — the one way anything leaves this station.
 *
 * A wapp does not transmit. It says what it wants said and to whom, and the
 * core composes the packet, seals it if it can, signs it, splits it (§6.6),
 * chooses the bearers (§36.0), parks a custody copy and reports back. Every
 * decision in that list is a transport decision, and none of them belongs to
 * somebody else's code.
 *
 * Two verbs, because there are two acts. [XprsSend.message] says something TO
 * SOMEBODY: it can be sealed, it is carried when they are away, and a receipt
 * comes back. [XprsSend.broadcast] says something TO WHOEVER IS IN REACH: it
 * has no recipient, so it cannot be sealed, is not carried and is never
 * receipted. Folding the second into the first by allowing an empty `to:`
 * would put four `if (dest.isEmpty)` branches inside a method whose whole
 * contract — the key lookup, the §18.1 ask, the custody park, the outbox row —
 * is about one named station.
 *
 * ── What this replaces ───────────────────────────────────────────────────
 *
 * `hal_ble_advertise`, which handed the core arbitrary bytes and made it SNIFF
 * them to pick a subtype byte for the wire — the exact guess `enqueueAdvert`
 * had a required `subtype:` parameter to prevent, reintroduced one call later.
 *
 * `hal_lxmf_send2`, which named one Reticulum destination: a wapp choosing a
 * transport, and choosing the one transport that cannot reach a station over
 * the radio in the same room.
 *
 * And a wapp's own idea of what to do when sealing is impossible. §36.8 is not
 * a preference: plaintext is disclosure, and the two forms are released under
 * different rules, so a request to seal that cannot be met is REFUSED and said
 * out loud. It is never quietly downgraded.
 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../profile/profile_service.dart';
import '../log_service.dart';
import '../mesh/mesh_custody.dart';
import '../reticulum/rns_service.dart';
import 'xprs_body.dart';
import 'xprs_id.dart';
import 'xprs_outbox.dart';
import 'xprs_packet.dart';
import 'xprs_publisher.dart';

/// What became of a send, answered before the bearers have finished with it.
///
/// A caller needs two things immediately: whether the words are sealed, so it
/// can label the bubble with what actually happened rather than what was asked
/// for; and the §5 identifier, so the bubble and the core's outbox are keyed on
/// the same value and a receipt can find it.
class XprsSendOutcome {
  const XprsSendOutcome({
    required this.form,
    required this.id,
    required this.parts,
    this.refusal,
  });

  /// 'x' sealed, 'm' plain, '' nothing was sent.
  final String form;

  /// §5 identifier of the packet (of the REASSEMBLED packet when split, which
  /// is what the receiver derives and what a receipt names).
  final String id;

  final int parts;

  /// Why nothing was sent, when [form] is empty.
  final XprsSealRefusal? refusal;

  bool get ok => form.isNotEmpty;

  /// The integer a wasm caller reads: 1 sealed, 2 plain, -1 asked to seal and
  /// could not, 0 malformed or refused for another reason.
  int get code {
    if (form == 'x') return 1;
    if (form == 'm') return 2;
    return refusal == XprsSealRefusal.noRecipientKey ? -1 : 0;
  }

  static const XprsSendOutcome malformed =
      XprsSendOutcome(form: '', id: '', parts: 0);
}

class XprsSend {
  XprsSend._();
  static final XprsSend instance = XprsSend._();

  static int sent = 0;
  static int refused = 0;

  /// Send [text] to [to] as a `t:message`.
  ///
  /// [private] asks for §9.2's sealed body. It is a request, not a mode: when
  /// the recipient's key has not been heard the send is refused, the key is
  /// asked for (§18.1), and the caller is told — because a sealed message that
  /// silently went out in the clear is the failure nobody notices.
  ///
  /// Returns as soon as the packet exists. Airing it is the publisher's, and
  /// happens after this returns.
  XprsSendOutcome message(String to, String text, {required bool private}) {
    final self =
        (ProfileService.instance.activeProfile?.callsign ?? '').trim().toUpperCase();
    final dest = to.trim().toUpperCase();
    if (self.isEmpty || dest.isEmpty || text.isEmpty) {
      refused++;
      return XprsSendOutcome.malformed;
    }

    final head = XprsPacket.parse('t:message f:$self d:$dest ts:${_now()}');
    if (head == null) {
      refused++;
      return XprsSendOutcome.malformed;
    }

    final built = xprsBuildDirect(
      head: head,
      text: text,
      private: private,
      // The key the recipient published in their own `t:identity` (§9.3),
      // learned from the air and re-announced every half hour (§18.1).
      recipientKeyHex: private
          ? (RnsService.instance.pubkeyForCallsign(dest) ?? '')
          : null,
    );

    if (!built.ok) {
      refused++;
      if (built.refusal == XprsSealRefusal.noRecipientKey) {
        // §18.1: ask for the key rather than wait for the next announcement.
        unawaited(XprsPublisher.instance.askIdentity(dest));
      }
      LogService.instance
          .add('XPRS send to $dest refused: ${built.refusal?.name}');
      return XprsSendOutcome(
          form: '', id: '', parts: 0, refusal: built.refusal);
    }

    // The identifier of the whole message. When the body was split, that is
    // the packet the parts reassemble into — the value the RECEIVER derives,
    // and the one a receipt names in `r:`.
    final id = xprsIdentifier(built.rejoined ?? built.packets.first);

    unawaited(_air(built.packets, dest: dest, id: id));
    sent++;
    return XprsSendOutcome(
      form: built.privacy == XprsPrivacy.sealed ? 'x' : 'm',
      id: id,
      parts: built.packets.length,
    );
  }

  /// Say [text] to everybody in reach, as an undirected `t:message`.
  ///
  /// The undirected half of [message]. [scope] is §13.11's reach — `local` for
  /// the bearers in range now (§13.11.1), `global` for everywhere, or ISO
  /// 3166-1 alpha-2 codes. [replyTo] is the §5 identifier this post answers
  /// (§6.4), empty for none.
  ///
  /// THERE IS NO `private`. §9.2 seals to ONE public key and a broadcast has no
  /// recipient, so this door does not offer a promise it could never keep —
  /// which is different from [message], where the request is meaningful and a
  /// refusal is the answer. [XprsSendOutcome.form] is `m` on success, always.
  ///
  /// No custody copy and no outbox row; see [_airBroadcast] for why.
  XprsSendOutcome broadcast(String text,
      {String scope = 'local', String replyTo = ''}) {
    final self = (ProfileService.instance.activeProfile?.callsign ?? '')
        .trim()
        .toUpperCase();
    if (self.isEmpty || text.trim().isEmpty) {
      refused++;
      return XprsSendOutcome.malformed;
    }

    final reach = scope.trim().toLowerCase();
    if (!scopeOk(reach)) {
      // A word nobody defined must not reach the wire: `xprsScope` would read
      // it as a country list and the publisher would gate every bearer on it,
      // so a typo would become silence rather than an error.
      refused++;
      return XprsSendOutcome.malformed;
    }

    var head = 't:message f:$self ts:${_now()}';
    // §13.11: global IS the absent field. Writing `scope:global` would be
    // twelve bytes saying the default on a bearer that charges by the byte.
    if (reach.isNotEmpty && reach != 'global') head += ' scope:$reach';
    final parent = replyTo.trim().toLowerCase();
    if (parent.isNotEmpty) head += ' r:$parent';

    final h = XprsPacket.parse(head);
    if (h == null) {
      refused++;
      return XprsSendOutcome.malformed;
    }

    // The same plain path a 1:1 gets — §9.1 signing, §6.6 splitting at spaces
    // with the signature over the reassembled packet (§9.1.1) — minus the seal
    // it cannot have.
    final built = xprsBuildDirect(head: h, text: text, private: false);
    if (!built.ok) {
      refused++;
      LogService.instance
          .add('XPRS broadcast refused: ${built.refusal?.name}');
      return XprsSendOutcome(
          form: '', id: '', parts: 0, refusal: built.refusal);
    }

    final id = xprsIdentifier(built.rejoined ?? built.packets.first);
    unawaited(_airBroadcast(built.packets, id: id));
    sent++;
    return XprsSendOutcome(form: 'm', id: id, parts: built.packets.length);
  }

  /// `local`, `global`, or a comma list of ISO 3166-1 alpha-2 codes (§13.11).
  ///
  /// Public so it can be tested on its own: a scope word is the difference
  /// between "the people in this building" and "everyone", and a typo that
  /// reached the wire would be read as a country list and silence every
  /// bearer — a failure that looks exactly like a radio that is off.
  static bool scopeOk(String s) {
    if (s.isEmpty || s == 'local' || s == 'global') return true;
    // Uppercase on the wire; lowercased here, so check the shape, not the case.
    for (final c in s.split(',')) {
      final t = c.trim();
      if (t.length != 2) return false;
      for (final u in t.codeUnits) {
        if (u < 0x61 || u > 0x7a) return false;
      }
    }
    return true;
  }

  /// Airing, and nothing else.
  ///
  /// NO CUSTODY PARK. §13.11.3 says a `local` packet is not carried, and
  /// [MeshCustodyDelegate] refuses it twice over — an undirected packet names
  /// no station to carry it to, and the scope is refused on top. Calling it
  /// would be a log line saying no.
  ///
  /// NO [XprsOutbox.noteSent]. §13.7.1's first exclusion is a packet with no
  /// destination: nobody owes a receipt for a broadcast, so a row recorded here
  /// could only ever sit at `sent`. An outbox row that can never advance is a
  /// tick that never arrives, and a bug with no name.
  Future<void> _airBroadcast(List<XprsPacket> parts,
      {required String id}) async {
    for (var i = 0; i < parts.length; i++) {
      // ITS OWN ADVERT SLOT, per message and per part.
      //
      // Registering a slot replaces whatever frame is in it. The default for a
      // packet with no `d:` is the bare type (`publishWire`), so every Local
      // post this station ever made would key on the single string `message`
      // and evict its predecessor before the rotation reached it — two posts
      // in a minute, one on the air. The same reasoning `moderate` already
      // carries there: a distinct record keys on its own §5 identifier.
      await XprsPublisher.instance
          .publishWire(parts[i].encode(), slot: 'message:$id:${i + 1}');
    }
  }

  Future<void> _air(List<XprsPacket> parts,
      {required String dest, required String id}) async {
    for (final part in parts) {
      await XprsPublisher.instance.publishWire(part.encode());
      // Park a custody copy of exactly the bytes that went out — the signed
      // wire, not the one composed here, or the parked copy and the air carry
      // different identifiers and a receipt releases neither.
      final signed = XprsPublisher.instance.lastWire ?? part.encode();
      try {
        MeshCustodyDelegate.onAirFrame(Uint8List.fromList(utf8.encode(signed)),
            outbound: true);
      } catch (_) {
        // Custody is best-effort; a message that went out is out.
      }
    }
    XprsOutbox.instance.noteSent(id, dest);
  }

  static String _now() {
    final n = DateTime.now().toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}-${two(n.month)}-${two(n.day)}_'
        '${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
  }

  static void debugReset() {
    sent = 0;
    refused = 0;
  }
}
