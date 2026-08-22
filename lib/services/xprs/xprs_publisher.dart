/// Publishing an XPRS packet on every bearer this device has.
///
/// The one place that answers "which transports, right now" — a wapp hands the
/// core CONTENT (`hal_xprs_status`) and this service decides where it travels
/// (docs/architecture.md rule 1: transports are core; a wapp never chooses a
/// radio). Today that is BLE5 extended advertising and a Reticulum broadcast;
/// LoRa holds a visible slot that activates the day the radio exists.
///
/// `scope:` (docs/XPRS.md section 13.11) gates reach: a `local` packet stays
/// on the short-range bearers, a country scope is not gatewayed by a node
/// that cannot place itself, and the default — global — goes everywhere
/// active, which is xprs's stated behaviour.
///
/// Long content splits into section 6.6 parts (at most nine, split only at
/// spaces, same `ts:` throughout) and the signature covers the REASSEMBLED
/// packet, riding the last part (sections 9.1.1 and 25.5). No profile key →
/// transmit unsigned, which the spec permits and the log states.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../connections/bluetooth/ble5_bus.dart';
import '../../connections/lora/lora_connection.dart';
import '../../connections/connection.dart';
import '../../profile/profile_service.dart';
import '../log_service.dart';
import '../reticulum/rns_service.dart';
import 'xprs_ingest.dart';
import 'xprs_lan.dart';
import 'xprs_packet.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

/// One way bytes can leave this device.
///
/// Deliberately tiny: the publisher asks two questions — are you on, and did
/// you take it — and applies the scope rules itself so every future bearer
/// (LoRa, a KISS TNC, WiFi Aware) inherits them by construction.
abstract class XprsBearer {
  String get name;

  /// What the spool calls this bearer. Usually the same word; the two that
  /// differ do so because the archive names a medium (`ble`) where the
  /// publisher names a radio generation (`ble5`).
  String get archiveBearer => name;

  /// Whether a `scope:local` packet may use this bearer (section 13.11.1:
  /// local names the short-range bearers, not a distance).
  bool get shortRange;

  Future<bool> get active;

  /// Transmit one wire. [part] distinguishes the parts of a split packet so
  /// an advert-style bearer can rotate them under distinct keys.
  ///
  /// [slot] names WHAT is being aired ('status', 'ask:X3WWAJ', 'identity').
  /// An advert-style bearer keys its rotation entry by it, and re-registering
  /// a key REPLACES that entry's payload — so everything sharing one slot
  /// clobbered everything else. A catch-up sweep asking N stations back to
  /// back put only the LAST ask on air, and a status the user had just
  /// published went with it.
  /// [ttl] is how long an advert-style bearer should keep the frame on air.
  /// Only such a bearer has any use for it -- a datagram is sent once and is
  /// gone -- so it is optional and each bearer falls back to its own default.
  /// It exists because a replayed history page is twelve frames paced 1.5 s
  /// apart: at the advertiser's 120 s default they would all still be on air
  /// long after the page ended, holding twelve rotation slots against
  /// everything else this station has to say.
  Future<bool> send(String wire,
      {required int part, String slot = 'status', Duration? ttl});
}

class _Ble5Bearer implements XprsBearer {
  @override
  String get name => 'ble5';
  @override
  String get archiveBearer => 'ble';
  @override
  bool get shortRange => true;
  @override
  // Both halves matter: the controller must do extended advertising at all, and
  // the radio must be on this second. supported() alone is a capability probe
  // cached for the life of the process, so it kept reporting this bearer active
  // with Bluetooth switched off — every ask composed, signed and dropped.
  Future<bool> get active async =>
      await Ble5Bus.instance.supported() && await Ble5Bus.instance.adapterOn();
  @override
  Future<bool> send(String wire,
          {required int part, String slot = 'status', Duration? ttl}) =>
      Ble5Bus.instance.advertiseFrame(
        'xprs-$slot:$part',
        Ble5Subtype.xprs,
        Uint8List.fromList(utf8.encode(wire)),
        // Long enough to span a receiver's duty-cycled scan burst — the same
        // rationale hal_ble_advertise documents for its 120 s. A caller that
        // knows better (a paced replay) says so.
        ttl: ttl ?? const Duration(seconds: 120),
      );
}

class _ReticulumBearer implements XprsBearer {
  @override
  String get name => 'reticulum';
  @override
  String get archiveBearer => 'rns';
  @override
  bool get shortRange => false;
  @override
  Future<bool> get active async => RnsService.instance.isUp;
  @override
  Future<bool> send(String wire,
          {required int part, String slot = 'status', Duration? ttl}) =>
      RnsService.instance.wappBroadcast(
          'xprs', Uint8List.fromList(utf8.encode(wire)));
}

class _LanBearer implements XprsBearer {
  @override
  String get name => 'lan';
  @override
  String get archiveBearer => 'lan';
  // The wire in the building is short-range in the sense section 13.11.1
  // means: a `scope:local` packet on it reaches the machines here and stops.
  @override
  bool get shortRange => true;
  @override
  Future<bool> get active async => XprsLan.instance.up;
  @override
  Future<bool> send(String wire,
          {required int part, String slot = 'status', Duration? ttl}) async =>
      XprsLan.instance.send(wire);
}

class _LoraBearer implements XprsBearer {
  // The slot the user asked to see: when a LoRa radio ships, its connection
  // reports available and statuses start riding it with no publisher change.
  final LoraConnection _lora = LoraConnection();
  @override
  String get name => 'lora';
  @override
  String get archiveBearer => 'lora';
  @override
  bool get shortRange => true;
  @override
  Future<bool> get active async =>
      _lora.status == ConnectionStatus.available;
  @override
  Future<bool> send(String wire,
          {required int part, String slot = 'status', Duration? ttl}) async =>
      false;
}

class XprsPublisher {
  XprsPublisher._();
  static final XprsPublisher instance = XprsPublisher._();

  /// Replaceable for tests; order is presentation only (every active bearer
  /// is used).
  List<XprsBearer> bearers = [
    _Ble5Bearer(),
    _LanBearer(),
    _ReticulumBearer(),
    _LoraBearer()
  ];

  int published = 0;
  int refused = 0;

  /// Publish a `t:status` (section 27). Returns per-bearer outcomes:
  /// 'sent' | 'refused' | 'inactive' | 'scope' — empty map when nothing
  /// could be published at all (no profile, empty text).
  Future<Map<String, String>> publishStatus(String text,
      {String? mood, String? scope}) async {
    final body = text.trim();
    final call =
        (ProfileService.instance.activeProfile?.callsign ?? '').trim();
    if (body.isEmpty || call.isEmpty) {
      refused++;
      LogService.instance.add(
          'XPRS: status not published — ${body.isEmpty ? "empty" : "no profile callsign yet"}');
      return const {};
    }

    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${now.year}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';

    var head = 't:status f:${call.toUpperCase()} ts:$ts';
    if (mood != null && mood.trim().isNotEmpty) {
      head += ' mood:${mood.trim().toLowerCase()}';
    }
    if (scope != null && scope.trim().isNotEmpty) {
      head += ' scope:${scope.trim()}';
    }

    final wires = _wires(head, body);
    if (wires.isEmpty) {
      refused++;
      return const {};
    }

    final p0 = XprsPacket.parse(wires.first);
    final local = p0 != null && xprsScope(p0).scope != XprsScope.global;

    final report = <String, String>{};
    String? carriedBy;
    for (final b in bearers) {
      if (local && !b.shortRange) {
        // A local packet never leaves the short-range bearers (13.11.1), and
        // a node that cannot place itself does not gateway a country scope
        // (13.11.3) — both land here.
        report[b.name] = 'scope';
        continue;
      }
      if (!await b.active) {
        report[b.name] = 'inactive';
        continue;
      }
      var ok = true;
      for (var i = 0; i < wires.length; i++) {
        ok = await b.send(wires[i], part: i + 1) && ok;
      }
      report[b.name] = ok ? 'sent' : 'refused';
      if (ok) carriedBy ??= b.archiveBearer;
    }

    // Our own publication enters our own spool whether or not a radio took
    // it. A cmd:history asked of the author must be able to replay the author
    // (section 36.5), and the words exist either way: this used to be gated on
    // `carriedBy != null`, so a status composed with no bearer active was
    // never stored, never shown, and reported no error. The bearer records
    // what actually carried it, or `none` when nothing did — an honest row
    // rather than an absent one.
    //
    // Written once per wire AFTER the send loop, deliberately: the ON CONFLICT
    // clause in the archive does not update `bearer` and does increment
    // `heard`, so recording first and amending later would leave the bearer
    // empty and count one packet as heard twice.
    for (final w in wires) {
      XprsIngest.own(w, bearer: carriedBy ?? 'none');
    }

    published++;
    LogService.instance.add('XPRS: status (${wires.length} part'
        '${wires.length == 1 ? "" : "s"}) — ${report.entries.map((e) => "${e.key}:${e.value}").join(", ")}');
    return report;
  }

  /// Publish this station's `t:mailbox hold:` declaration (section 13.12):
  /// the stations mail for us should be left with, in preference order.
  /// MUST be signed -- a forged declaration steals mail, so with no signing
  /// key nothing is aired and the log says why. Returns per-bearer outcomes.
  Future<Map<String, String>> publishMailboxDecl(String holdCsv) async {
    final call =
        (ProfileService.instance.activeProfile?.callsign ?? '').trim();
    final hold = holdCsv
        .split(',')
        .map((c) => c.trim().toUpperCase())
        .where((c) => c.isNotEmpty)
        .join(',');
    if (call.isEmpty || hold.isEmpty) return const {};

    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${now.year}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';

    var p = XprsPacket.parse(
        't:mailbox f:${call.toUpperCase()} ts:$ts hold:$hold');
    if (p == null || !p.fits) return const {};
    final d = xprsProfileScalar();
    if (d == null) {
      LogService.instance.add(
          'XPRS: mailbox declaration NOT aired — no signing key, and an '
          'unsigned one must be ignored (13.12)');
      return const {};
    }
    p = xprsSign(p, d);
    final wire = p.encode();

    final report = <String, String>{};
    String? carriedBy;
    for (final b in bearers) {
      if (!await b.active) {
        report[b.name] = 'inactive';
        continue;
      }
      final ok = await b.send(wire, part: 1);
      report[b.name] = ok ? 'sent' : 'refused';
      if (ok) carriedBy ??= b.archiveBearer;
    }
    if (carriedBy != null) XprsIngest.own(wire, bearer: carriedBy);
    LogService.instance.add('XPRS: mailbox hold:$hold — '
        '${report.entries.map((e) => "${e.key}:${e.value}").join(", ")}');
    return report;
  }

  /// Announce the key this callsign signs with (section 9.3).
  ///
  /// Until this existed no station could check a single signature of ours, so
  /// every packet we sent read `unverified` and every station metered us as a
  /// stranger — two history replays an hour instead of six (section 31.2).
  ///
  /// MUST be self-signed. The signature proves we hold the private half, which
  /// is not circular (section 9.3): without one, anybody can rebroadcast our
  /// callsign with our real key and whatever else they like attached. Both
  /// station firmwares drop an identity whose signature does not verify
  /// against the `k:` it carries, so an unsigned one binds nothing anywhere
  /// and is not aired.
  ///
  /// Deliberately carries NO `scope:`, so it is global and rides every active
  /// bearer. A key binding is not a local fact.
  ///
  /// `nick:` is deliberately omitted: the key-binding form is 171 bytes and
  /// the smallest controller measured in docs/ble5.md section 3 carries 184,
  /// where an oversized frame is refused rather than truncated.
  Future<Map<String, String>> publishIdentity() async {
    final profile = ProfileService.instance.activeProfile;
    final call = (profile?.callsign ?? '').trim().toUpperCase();
    final npub = (profile?.npub ?? '').trim();
    if (call.isEmpty || !npub.startsWith('npub1')) return const {};

    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final ts = '${now.year}-${two(now.month)}-${two(now.day)}_'
        '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';

    var p = XprsPacket.parse('t:identity f:$call ts:$ts k:$npub');
    if (p == null) return const {};
    final d = xprsProfileScalar();
    if (d == null) {
      LogService.instance.add(
          'XPRS: identity NOT aired — no signing key (locked profile?), and '
          'an unsigned identity binds nothing (9.3)');
      return const {};
    }
    p = xprsSign(p, d);
    if (!p.fits) return const {};
    final wire = p.encode();

    final report = <String, String>{};
    String? carriedBy;
    for (final b in bearers) {
      if (!await b.active) {
        report[b.name] = 'inactive';
        continue;
      }
      final ok = await b.send(wire, part: 1, slot: 'identity');
      report[b.name] = ok ? 'sent' : 'refused';
      if (ok) carriedBy ??= b.archiveBearer;
    }
    // 'none' rather than skipping: a period where the identity reached nobody
    // is a fact worth having in the spool.
    XprsIngest.own(wire, bearer: carriedBy ?? 'none');
    LogService.instance.add('XPRS: identity $call k:${npub.substring(0, 12)}… '
        '— ${report.entries.map((e) => "${e.key}:${e.value}").join(", ")}');
    return report;
  }

  /// Publish one caller-composed wire (spec/API-HTTP.md send semantics):
  /// validate section 4 syntax, sign it when it speaks as this station and
  /// carries no sig, apply the scope rules, air on every active bearer and
  /// spool our own copy. The caller owns the content.
  ///
  /// [slot] keeps concurrent publishes in separate advert rotation entries.
  /// It defaults to the packet's own type and destination, so two asks to two
  /// stations no longer overwrite each other and neither touches the status
  /// slot. Pass one explicitly only to group wires deliberately.
  /// Put one caller-composed wire on every bearer that will take it.
  ///
  /// [verbatim] is for a wire this station did not write: a history replay
  /// re-airs the AUTHOR's packet, byte for byte, with the author's own
  /// signature (25.2.1, 36.2). Two things that are right for our own words
  /// are wrong for someone else's, and both are skipped:
  ///   - signing. The wire's identifier is derived from its bytes, so adding
  ///     a signature to a stored record renames it, and the asker's `until:`
  ///     continuation would then be paging a record nobody else has.
  ///   - filing it as ours. It is already in the spool as something we HEARD;
  ///     re-entering it through [XprsIngest.own] would claim authorship of
  ///     another station's packet.
  Future<Map<String, String>> publishWire(String wireIn,
      {String? slot, Duration? ttl, bool verbatim = false}) async {
    LogService.instance.add('XPRS: publishWire <- $wireIn');
    var p = XprsPacket.parse(wireIn.trim());
    if (p == null || !p.fits) {
      LogService.instance.add('XPRS: publishWire rejected (parse/fit)');
      return const {};
    }
    final call =
        (ProfileService.instance.activeProfile?.callsign ?? '').trim();
    final from = (p['f'] ?? '').toUpperCase();
    if (!verbatim &&
        call.isNotEmpty &&
        from.split('-').first == call.toUpperCase().split('-').first &&
        !p.has('sig')) {
      final d = xprsProfileScalar();
      if (d != null) p = xprsSign(p, d);
    }
    final wire = p.encode();
    final local = xprsScope(p).scope != XprsScope.global;
    // `<type>` alone would still collide across destinations, which is exactly
    // the catch-up sweep's case: N asks, one slot, one survivor.
    final dest = (p['d'] ?? '').toUpperCase();
    final useSlot = slot ?? (dest.isEmpty ? p.type : '${p.type}:$dest');

    final report = <String, String>{};
    String? carriedBy;
    for (final b in bearers) {
      if (local && !b.shortRange) {
        report[b.name] = 'scope';
        continue;
      }
      if (!await b.active) {
        report[b.name] = 'inactive';
        continue;
      }
      final ok = await b.send(wire, part: 1, slot: useSlot, ttl: ttl);
      report[b.name] = ok ? 'sent' : 'refused';
      if (ok) carriedBy ??= b.archiveBearer;
    }
    if (!verbatim && carriedBy != null) {
      XprsIngest.own(wire, bearer: carriedBy);
    }
    published++;
    // One line per caller-composed wire: which bearers took it. A wire that
    // silently reached nobody is the failure mode that costs a day.
    LogService.instance.add(
        'XPRS: ${p.type} wire — ${report.entries.map((e) => '${e.key}:${e.value}').join(', ')}');
    return report;
  }

  /// Test seam: the exact wire [publishIdentity] would air, with [signingKey]
  /// standing in for the profile key (a unit test has no profile).
  String? debugIdentityWire(
      {required String call, required String npub, required BigInt signingKey, String? ts}) {
    final now = DateTime.now().toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp = ts ??
        '${now.year}-${two(now.month)}-${two(now.day)}_'
            '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
    final p = XprsPacket.parse('t:identity f:$call ts:$stamp k:$npub');
    if (p == null) return null;
    final signed = xprsSign(p, signingKey);
    return signed.fits ? signed.encode() : null;
  }

  /// Test seam: exactly the wires [publishStatus] would air for [head] and
  /// [body], with [signingKey] standing in for the profile key (a unit test
  /// has no profile).
  List<String> debugWires(String head, String body, {BigInt? signingKey}) =>
      _wires(head, body, signingKey: signingKey);

  /// The wires to air: one signed packet when it fits, else section 6.6
  /// parts with the reassembled packet's signature on the last (9.1.1).
  List<String> _wires(String head, String body, {BigInt? signingKey}) {
    final d = signingKey ?? xprsProfileScalar();

    XprsPacket? make(String m) => XprsPacket.parse('$head m:$m');

    // The unsplit packet, signed, when it fits.
    final whole = make(body);
    if (whole == null) return const [];
    final signedWhole = d != null ? xprsSign(whole, d) : whole;
    if (signedWhole.fits) return [signedWhole.encode()];

    // Split at spaces only (6.6). Every part reserves room for `n:i/9` AND
    // the signature, so whichever part ends up last still fits after the
    // sig is attached — a uniform budget beats a two-pass fit.
    final probe = make('')!.with_('n', '9/9').with_('sig', 'x' * 60);
    final capacity = XprsPacket.maxBytes - probe.byteLength;
    if (capacity <= 0) return const [];

    final chunks = <String>[];
    var current = StringBuffer();
    for (final word in body.split(' ')) {
      var w = word;
      // A word longer than a whole part (a monster URL) has no space to
      // split at; hard-cut it rather than lose everything after it.
      while (utf8.encode(w).length > capacity) {
        chunks.add(w.substring(0, capacity));
        w = w.substring(capacity);
      }
      final trial = current.isEmpty ? w : '$current $w';
      if (utf8.encode(trial).length > capacity) {
        if (current.isNotEmpty) chunks.add(current.toString());
        current = StringBuffer(w);
      } else {
        current = StringBuffer(trial);
      }
    }
    if (current.isNotEmpty) chunks.add(current.toString());

    if (chunks.length > 9) {
      // Nine parts is the format's ceiling (6.6); content past it is a
      // document, and a status is not one. Cut and say so.
      LogService.instance.add(
          'XPRS: status longer than nine parts — cut at part 9');
      chunks.removeRange(9, chunks.length);
    }

    // The signature covers the REASSEMBLED packet: joined m:, no n:.
    final joined = make(chunks.join(' '))!;
    final sig = d != null ? xprsSign(joined, d)['sig'] : null;

    final n = chunks.length;
    final out = <String>[];
    for (var i = 0; i < n; i++) {
      var part = make(chunks[i])!.with_('n', '${i + 1}/$n');
      if (i == n - 1 && sig != null) part = part.with_('sig', sig);
      out.add(part.encode());
    }
    return out;
  }
}
