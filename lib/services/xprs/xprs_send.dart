/*
 * xprs_send — the one way anything leaves this station.
 *
 * A wapp does not transmit. It says what it wants said and to whom, and the
 * core composes the packet, seals it if it can, signs it, splits it (§6.6),
 * chooses the bearers (§36.0), parks a custody copy and reports back. Every
 * decision in that list is a transport decision, and none of them belongs to
 * somebody else's code.
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
