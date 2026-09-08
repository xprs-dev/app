/*
 * xprs_mailbox — the archiver in the middle, and what the three stations owe
 * each other.
 *
 * The failure this exists to end (reported 2026-09-08, and it is the oldest
 * failure in messaging): A writes to B, B is asleep, A's radio goes in a
 * pocket. Nothing that was still awake held a copy, so when B woke there was
 * nobody to deliver it and the message was simply gone. A retry ladder on A
 * cannot fix this — A is the station that left.
 *
 * XPRS.md 12.7 and 12.8.1 answer it: an archiver is a mailbox, it is always on
 * because that is what it is for, and it delivers what it holds the moment it
 * can reach the recipient. Every piece of that was already in this code except
 * the three joins between them, which is why mail still died: nothing DEPOSITED
 * with an archiver, nothing told the archiver's holder it could stop, and no
 * station ever said where its own mailbox was.
 *
 * This file is those three joins, and nothing else:
 *
 *   1. **the deposit** — a directed packet WE originated that has no receipt
 *      after the direct attempt is copied to our archivers, verbatim, so the
 *      copy outlives us. Any type, not just chat: the core moves packets and
 *      does not read them (docs/architecture.md 3).
 *   2. **the declaration** — `t:mailbox hold:` says where our mailbox is, so
 *      the far side can send its receipt there and the archiver can stop.
 *   3. **the receipt's other addresses** — a receipt goes to the sender AND to
 *      whoever is holding a copy on the sender's behalf: the holders named in
 *      `via:`, and the sender's declared mailboxes. Delivery is what ends
 *      custody (12.7), and a receipt only the sender hears ends it only for a
 *      station that is not holding anything.
 *
 * The archiver half — hold, retry, release — is [sweepHeld] plus the release
 * on hearing that MeshService already runs (12.8.1).
 *
 * Nothing here decides a lane or touches a bearer: the sends are injected, so
 * the whole file runs in the simulation (test/support/mail_relay_sim.dart)
 * against a virtual air, which is how the three-station dance was made to work
 * before any of it went near a radio.
 */
library;

import 'dart:async';

import '../log_service.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_vocab.dart';

/// Counters, because a delivery that quietly did not happen is the whole
/// subject of this file (docs/performance.md 8.10: counters, not a log line
/// per packet).
class XprsMailboxCounters {
  static int deposited = 0;
  static int depositFailed = 0;
  static int depositSkipped = 0;
  static int depositNoArchiver = 0;
  static int declared = 0;
  static int receiptsToHolders = 0;
  static int sweepDelivered = 0;
  static int sweepSkipped = 0;

  static Map<String, int> get json => {
        'deposited': deposited,
        'depositFailed': depositFailed,
        'depositSkipped': depositSkipped,
        'depositNoArchiver': depositNoArchiver,
        'declared': declared,
        'receiptsToHolders': receiptsToHolders,
        'sweepDelivered': sweepDelivered,
        'sweepSkipped': sweepSkipped,
      };

  static void debugReset() {
    deposited = depositFailed = depositSkipped = depositNoArchiver = 0;
    declared = receiptsToHolders = sweepDelivered = sweepSkipped = 0;
  }
}

/// One packet this station is holding for somebody else.
class HeldMail {
  const HeldMail({required this.key, required this.target, required this.wire});
  final String key;
  final String target;
  final String wire;
}

class XprsMailbox {
  XprsMailbox._();
  static final XprsMailbox instance = XprsMailbox._();

  // ── injected by the core (mesh_service); never reached for directly ───────

  /// The archivers this station leans on, in preference order.
  List<String> Function()? archivers;

  /// This station's own callsign, bare.
  String Function()? selfCallsign;

  /// Send one wire to one callsign over whatever directed lane exists,
  /// verbatim. Returns false when there is no lane — which is not a failure,
  /// only a "not now".
  Future<bool> Function(String call, String wire)? sendTo;

  /// Sign and air a wire we are composing ourselves (the declaration).
  Future<void> Function(String wire)? publish;

  /// Whether a receipt for this identifier has come back yet.
  String? Function(String id)? outboxState;

  /// The stations a callsign declared as its mailboxes (12.8.1 step 1).
  List<String> Function(String callsign)? holdersOf;

  /// What we are holding for other people, and how to drop it.
  List<HeldMail> Function()? held;
  bool Function(String target)? reachable;
  void Function(String key)? noteAttempt;

  /// How long a directed packet gets to be acknowledged before we assume the
  /// far side is not there and hand a copy to an archiver.
  ///
  /// Not tuned for speed: a deposit that races a delivery costs one packet on
  /// a cheap lane, and a deposit that never happens costs the message. The
  /// courier's own no-path verdict lands at 20 s, so this sits just past it.
  Duration depositAfter = const Duration(seconds: 30);

  final Map<String, Timer> _armed = {};

  /// A directed packet we just sent. Hold it for [depositAfter]; if no receipt
  /// has arrived by then, give a copy to our archivers.
  ///
  /// Everything about this is deliberately type-blind. The core carries
  /// packets and does not read them: a chat message, a file description, a
  /// group act and a receipt are all mail addressed to somebody who may be
  /// asleep, and the chat wapp has no idea any of this happens.
  void armDeposit(String wire) {
    final p = XprsPacket.parse(wire);
    if (p == null) return;
    final dest = (p['d'] ?? '').trim().toUpperCase();
    final self = (selfCallsign?.call() ?? '').trim().toUpperCase();
    if (dest.isEmpty || self.isEmpty) return;
    if ((p['f'] ?? '').trim().toUpperCase() != self) return; // only our own
    if (!xprsAddressesStation(dest)) return; // a group has no mailbox (12.8.1)
    if (!xprsMayCarry(p)) return; // 13.11.1: local is for the bearers in range
    if (p.has('via')) return; // relayed traffic is not ours to deposit
    if (!worthKeeping(p)) return;
    final id = xprsIdentifier(p);
    if (_armed.containsKey(id)) return;
    _armed[id] = Timer(depositAfter, () {
      _armed.remove(id);
      unawaited(depositIfUnanswered(wire, id: id));
    });
  }

  /// Is this packet worth leaving with an archiver for later?
  ///
  /// Almost everything is: the core carries packets on a person's behalf and
  /// does not read them. The exception is the live negotiation of a transfer —
  /// a `cmd:file` carrying the chunk map the asker lacks RIGHT NOW, or the
  /// `t:result` answering one. Delivered tomorrow those ask a station to send
  /// bytes to somebody who stopped waiting, which is airtime spent on a
  /// question that has expired. `cmd:history` and a plain `cmd:file` are not
  /// this: they are still worth asking late.
  static bool worthKeeping(XprsPacket p) {
    if (p.type == 'command') return !(p.has('have') || p.has('off'));
    if (p.type == 'result') return !(p.has('have') || p.has('off'));
    return true;
  }

  /// The deposit itself. Public so a station that knows it has no path can
  /// deposit at once rather than wait out the window.
  Future<int> depositIfUnanswered(String wire, {String? id}) async {
    final p = XprsPacket.parse(wire);
    if (p == null) return 0;
    final ident = id ?? xprsIdentifier(p);
    final state = outboxState?.call(ident);
    if (state != null && state != 'sent') {
      // Delivered or read: the copy would be spent on a message that arrived.
      XprsMailboxCounters.depositSkipped++;
      return 0;
    }
    final list = (archivers?.call() ?? const <String>[])
        .map((c) => c.trim().toUpperCase())
        .where((c) => c.isNotEmpty)
        .toList();
    final self = (selfCallsign?.call() ?? '').trim().toUpperCase();
    final dest = (p['d'] ?? '').trim().toUpperCase();
    if (list.isEmpty) {
      XprsMailboxCounters.depositNoArchiver++;
      return 0;
    }
    var sent = 0;
    for (final a in list) {
      if (a == self || a == dest) continue;
      // VERBATIM, and with no `via:` of our own: this is not a relay, it is
      // the author handing a copy to the station it chose to keep its mail
      // (12.3). The archiver stores exactly what the recipient must verify,
      // signature included, and the hop budget (13.1) is untouched — the
      // deposit spent none of it.
      final ok = await (sendTo?.call(a, wire) ?? Future.value(false));
      if (ok) {
        sent++;
      } else {
        // A deposit that did not go out is the failure this whole file exists
        // to prevent, and it must never be silent: without a counter here the
        // difference between "no archiver" and "the archiver was unreachable"
        // is invisible, and on the bench they look identical — nothing
        // happened.
        XprsMailboxCounters.depositFailed++;
        LogService.instance
            .add('Mailbox: could not reach $a to leave a copy of ${p.type} '
                'for $dest');
      }
    }
    if (sent > 0) {
      XprsMailboxCounters.deposited += sent;
      LogService.instance.add(
          'Mailbox: ${p.type} for $dest deposited with $sent archiver(s) — '
          'no receipt after ${depositAfter.inSeconds}s (12.7)');
    }
    return sent;
  }

  /// `t:mailbox hold:` — where this station's mail should be left (13.12).
  ///
  /// Composed and aired whenever the archiver list changes, because it is the
  /// only way anybody else can learn where to send a receipt, and a receipt
  /// that never reaches the holder is why an archiver re-airs mail that
  /// arrived days ago.
  String? declaration({required String self, required List<String> holds}) {
    final me = self.trim().toUpperCase();
    final list = holds
        .map((c) => c.trim().toUpperCase())
        .where((c) => c.isNotEmpty && c != me)
        .toList();
    if (me.isEmpty || list.isEmpty) return null;
    return 't:mailbox f:$me ts:${xprsNowTs()} hold:${list.join(",")}';
  }

  Future<bool> declare() async {
    final self = (selfCallsign?.call() ?? '').trim().toUpperCase();
    final wire =
        declaration(self: self, holds: archivers?.call() ?? const <String>[]);
    if (wire == null || publish == null) return false;
    await publish!(wire);
    XprsMailboxCounters.declared++;
    LogService.instance.add('Mailbox: declared ${wire.split("hold:").last} '
        'as this station\'s mailbox (13.12)');
    return true;
  }

  /// Everyone besides the sender who should hear a receipt for [source].
  ///
  /// Two kinds, and both are stations that may be HOLDING a copy right now:
  ///
  ///   - the relays in `via:`: they carried it, so they have it;
  ///   - the sender's declared mailboxes: the sender deposited with them, and
  ///     they will keep re-delivering until somebody tells them not to.
  ///
  /// This is the join that was missing. A receipt that goes only to the sender
  /// ends the sender's ladder and leaves every holder still trying — and the
  /// sender is precisely the station that is offline, which is why an archiver
  /// held the copy in the first place.
  List<String> receiptFanout(XprsPacket source, {required String selfBase}) {
    final self = selfBase.trim().toUpperCase();
    final from = (source['f'] ?? '').trim().toUpperCase();
    final out = <String>[];
    void add(String c) {
      final v = c.trim().toUpperCase();
      if (v.isEmpty || v == self || v == from || out.contains(v)) return;
      if (!xprsAddressesStation(v)) return;
      out.add(v);
    }

    for (final v in (source['via'] ?? '').split(',')) {
      add(v);
    }
    for (final h in holdersOf?.call(from) ?? const <String>[]) {
      add(h);
    }
    return out;
  }

  /// The archiver's own duty: try again, for everything held whose recipient
  /// is reachable now.
  ///
  /// The release-on-hearing of 12.8.1 covers the recipient that SPEAKS to us.
  /// An always-on archiver on the internet mostly does not hear the recipient
  /// speak — it learns the recipient exists because a path to them appeared —
  /// so without this sweep an internet mailbox holds mail forever while the
  /// recipient sits online three hops away.
  ///
  /// [max] bounds one round: a release is a page (12.8.2), and a backlog of
  /// two hundred must not become two hundred sends in one second.
  Future<int> sweepHeld({int max = 8}) async {
    final rows = held?.call() ?? const <HeldMail>[];
    if (rows.isEmpty) return 0;
    final me = (selfCallsign?.call() ?? '').trim().toUpperCase();
    var done = 0;
    for (final m in rows) {
      if (done >= max) break;
      // Never "deliver" to ourselves. A copy of our OWN mail sits in this same
      // store — the courier parks one so a carrier can pick it up — and
      // sweeping it would put a packet on the air addressed to this station,
      // which every neighbour then hears us relay to nobody.
      if (m.target.trim().toUpperCase() == me) {
        XprsMailboxCounters.sweepSkipped++;
        continue;
      }
      if (!(reachable?.call(m.target) ?? false)) {
        XprsMailboxCounters.sweepSkipped++;
        continue;
      }
      noteAttempt?.call(m.key);
      // Delivering somebody else's mail IS a relay, so we sign it as one:
      // `via:` gains this station's callsign (12.8.1), which costs the packet
      // nothing it can spare and buys the two things custody needs. The loop
      // check gets an entry, and — the reason the receipt loop used to hang
      // open — the RECIPIENT learns who is holding a copy, and can tell that
      // station to stop. A sender that is asleep cannot pass the message on,
      // and the recipient has no other way to know an archiver was involved.
      var out = m.wire;
      final held = XprsPacket.parse(m.wire);
      if (held != null && me.isNotEmpty && !xprsVia(held).contains(me)) {
        final carried = xprsAppendVia(held, me);
        if (carried.fits) out = carried.encode();
      }
      final ok = await (sendTo?.call(m.target, out) ?? Future.value(false));
      if (!ok) continue;
      done++;
      XprsMailboxCounters.sweepDelivered++;
    }
    if (done > 0) {
      LogService.instance
          .add('Mailbox: delivered $done held packet(s) to reachable '
              'recipients (12.8.1)');
    }
    return done;
  }

  void debugReset() {
    for (final t in _armed.values) {
      t.cancel();
    }
    _armed.clear();
  }
}
