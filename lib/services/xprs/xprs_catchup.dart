/*
 * xprs_catchup — the pocket device polls its archivers (XPRS 36.10.1).
 *
 * A phone cannot tell an absence from an afternoon in a pocket, so it does
 * not try: it keeps one persisted WATERMARK — the end of the last window an
 * archiver answered for — and, on a slow cadence, asks every archiver in
 * direct reach for what came after it:
 *
 *   t:command f:<us> d:<archiver> ts:<now> cmd:history since:<watermark>
 *
 * The ask is DIRECTED, so it reaches exactly one station on whatever lane can
 * carry it -- including the internet, where a peer on another network is
 * reachable and a scope:local ask (13.11.3) would have been refused before it
 * left. The watermark advances to the
 * ask's own ts: only when the station answers 200/206/404; a 429 or silence
 * leaves it, and the same window is asked for again next period.
 *
 * EVERY station in direct reach is asked, on whatever bearer heard it — not
 * only the ones advertising serve:archive. A station that holds a message for
 * us is worth asking whether or not it calls itself an archive, and a phone
 * that waits to be told there is mail never finds out when the beacon carrying
 * that news is the one advert it missed.
 *
 * The period is one minute. That is a battery setting, not a freshness setting
 * (docs/performance.md section 6.5): it costs one small frame per station per
 * minute inside an advertising window that already opens, no GATT link, no
 * crypto, no sqlite. The expensive half — dialling a station to pull what it
 * holds — stays gated on a station actually saying it holds something.
 */
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../wapp/android_foreground_service.dart';
import '../hero/launcher_visibility.dart';
import '../log_service.dart';
import '../preferences_service.dart';
import '../reticulum/rns_service.dart';
import 'xprs_archive.dart';
import 'xprs_cadence.dart';
import 'xprs_id.dart';
import 'xprs_monitor.dart';
import 'xprs_packet.dart';
import 'xprs_publisher.dart';

class XprsCatchup {
  XprsCatchup._();
  static final XprsCatchup instance = XprsCatchup._();

  /// Test seams: fake clock and a captured send.
  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;
  Future<Map<String, String>> Function(String wire)? sendOverride;

  /// The ask window never reaches further back than this (36.10.1 rule 4).
  static const Duration maxWindow = Duration(days: 7);

  /// How far back a FIRST-RUN backfill reaches, and how many messages is
  /// enough of a conversation to arrive with.
  ///
  /// 36.10.1 rule 4 bounds a background poll to seven days and says in the
  /// same breath that "anything older is fetched deliberately, not by a
  /// background poll". This is that deliberate fetch: it runs once, on a
  /// device whose archive holds no conversation at all, so a fresh install
  /// opens Global chat with something in it instead of a blank page. The poll
  /// keeps its week.
  static const Duration backfillWindow = Duration(days: 30);
  static const int backfillMessages = 1000;

  /// The archiver a backfill is currently draining, if any. One at a time:
  /// asking three supers for the same month fetches the same conversation
  /// three times, and the responder meters each of them.
  String? _backfillStation;
  int _backfillFetched = 0;

  /// One ask per archiver per period.
  final Map<String, int> _askedAtMs = {};

  /// Per station, the last `count:`/`mail:` its beacon claimed. An unchanged
  /// pair means there is nothing to fetch, so no replay is spent.
  final Map<String, String> _newsSeen = {};

  /// Stations whose last page came back `206` — more was held than was served.
  /// Value is the `until:` for the continuation: the oldest ts we received, so
  /// the next ask asks for what came BEFORE it (section 36.10.1).
  final Map<String, int> _resume = {};

  /// Pending asks: section-5 id of the ask -> the ask's own ts (epoch ms).
  /// When a t:result names one of these with 200/206/404, the watermark
  /// advances to that ts.
  final Map<String, _Ask> _pending = {};
  static const int _pendingMax = 8;

  /// Per archiver, the interval it has earned, in ms. Persisted with the
  /// watermarks: an in-memory-only cadence resets to "ask everybody now" on
  /// every restart, which is exactly how a crash loop blows through a
  /// station's hourly budget with nothing to stop it.
  final Map<String, int> _intervalMs = {};

  /// Per archiver, when it last gave us something new. Drives the ladder:
  /// quiet for a week is an hour, quiet for three months is six hours.
  final Map<String, int> _lastNewsMs = {};

  /// Asks sent and not yet answered: archiver -> when we sent it.
  final Map<String, int> _inFlight = {};

  /// How long an unanswered ask blocks the next one. Long enough for a full
  /// page to air (twelve records at the responder's pacing, plus slack), short
  /// enough that a peer that simply went away does not mute us for a period.
  static const Duration _inFlightGrace = Duration(seconds: 40);

  /// Injected so the tests are deterministic; 0..1.
  double Function() rand = math.Random().nextDouble;

  bool _awaiting(String base, int now) {
    final sent = _inFlight[base];
    if (sent == null) return false;
    if (now - sent > _inFlightGrace.inMilliseconds) {
      _inFlight.remove(base);
      return false;
    }
    return true;
  }

  /// Is anybody looking? A fast cadence with the screen off spends somebody's
  /// battery on news no one is awake to read (docs/performance.md 6.5).
  bool get _visible => LauncherVisibility.instance.visible.value;

  /// What this peer will tolerate. Only a super-archiver's raised budgets
  /// (36.9.4) can serve a fast caller; our own other devices are not metered
  /// at all by the responder, so they count as fast too.
  XprsPeerClass _classOf(String base, String selfCallsign) {
    if (_operatorTrusted(base, selfCallsign)) return XprsPeerClass.fast;
    final st = XprsMonitor.instance.stations[base];
    final serves = st?.services ?? const <String>[];
    return serves.contains('super') ? XprsPeerClass.fast : XprsPeerClass.ordinary;
  }

  /// A super this operator actually agreed to: our own other device, or one
  /// they NAMED. Kept apart from a super we merely BELIEVE, because the two
  /// answer different questions and only this one may spend the battery
  /// without asking (see [_floorMsFor]).
  ///
  /// The named list is also the only way to learn a super reached solely over
  /// the internet: it is never heard on a radio, so it has no station record
  /// and no `serve:` list to read. Requiring the beacon meant the one archiver
  /// everybody pulls Global chat from was the one archiver nobody could poll
  /// quickly.
  bool _operatorTrusted(String base, String selfCallsign) {
    if (base == _base(selfCallsign)) return true;
    final chosen =
        PreferencesService.instanceSync?.xprsSuperArchivers ?? const <String>[];
    for (final c in chosen) {
      if (_base(c) == base) return true;
    }
    return false;
  }

  /// The fastest this archiver may be asked, right now.
  int _floorMsFor(String base, PreferencesService prefs) {
    final peer = _classOf(base, _selfCallsign);
    var floor = XprsCadence.floorFor(peer, visible: _visible).inMilliseconds;
    // The operator's own knob still applies, in the direction that is always
    // safe: xprsCatchupMinutes may make this station poll SLOWER than the
    // section 36.10.1 floor, never faster. Somebody minding their battery can
    // ask for less; nobody gets to ask an ordinary archiver for more than its
    // six replays an hour.
    //
    // The knob is waived only for a super this operator CHOSE. A super-archiver
    // is a claim, not a fact -- anything in earshot can beacon
    // `serve:archive,super` and a phone can say it -- so honouring a stranger's
    // claim here would let one beacon override the battery setting and turn a
    // once-a-minute poll into four. A claimed super still earns the raised
    // floor, it just never gets asked faster than its own operator allowed.
    final chosen = prefs.xprsCatchupMinutes * 60000;
    final trusted = _operatorTrusted(base, _selfCallsign);
    if (!trusted && chosen > floor) floor = chosen;
    return floor;
  }

  /// The interval this archiver has earned, clamped to the bounds that apply
  /// right now (they move with visibility and with how long it has been quiet).
  int _intervalFor(String base, PreferencesService prefs, int now) {
    final stored = _intervalMs[base] ??
        (prefs.xprsCatchupIntervals[base] ?? XprsCadence.initial.inMilliseconds);
    _intervalMs[base] ??= stored;
    final lastNews = _lastNewsMs[base] ?? prefs.xprsCatchupNews[base] ?? now;
    final silent = Duration(milliseconds: now - lastNews);
    final floor = _floorMsFor(base, prefs);
    final ceiling = XprsCadence.ceilingFor(silent).inMilliseconds;
    var ms = stored;
    if (ms > ceiling) ms = ceiling;
    if (ms < floor) ms = floor > ceiling ? ceiling : floor;
    return XprsCadence.jitter(Duration(milliseconds: ms), rand()).inMilliseconds;
  }

  /// Fold an answer into this archiver's cadence and persist it.
  void _noteAnswer(String base, XprsAnswer answer) {
    final prefs = PreferencesService.instanceSync;
    final now = nowMs();
    _inFlight.remove(base);
    if (answer == XprsAnswer.news) {
      _lastNewsMs[base] = now;
      prefs?.setXprsCatchupNews(base, now);
    }
    final silent = Duration(milliseconds: now - (_lastNewsMs[base] ?? now));
    final current = Duration(
        milliseconds: _intervalMs[base] ?? XprsCadence.initial.inMilliseconds);
    final next = XprsCadence.next(
      current: current,
      answer: answer,
      peer: _classOf(base, _selfCallsign),
      visible: _visible,
      silentFor: silent,
    );
    _intervalMs[base] = next.inMilliseconds;
    prefs?.setXprsCatchupInterval(base, next.inMilliseconds);
  }

  /// The user opened a room: an event beats a clock. Ask this archiver now,
  /// once, whatever the interval says -- the same escape hatch the mesh
  /// scheduler has in pokeFor.
  void pokeFor(String archiver) {
    final base = _base(archiver);
    if (base.isEmpty) return;
    _askedAtMs.remove(base);
    _inFlight.remove(base);
    if (_selfCallsign.isNotEmpty) unawaited(tick(_selfCallsign));
  }

  int get watermarkSec =>
      PreferencesService.instanceSync?.xprsCatchupWatermark ?? 0;

  /// How many stations we remember a mark for. Evicted oldest-mark-first, so a
  /// busy channel cannot grow this without bound.
  static const int _marksMax = 32;

  /// This station's own mark, or the shared seed for one never asked before.
  int _markFor(String station, PreferencesService prefs) =>
      prefs.xprsCatchupMarks[station] ?? prefs.xprsCatchupWatermark;

  void _setMark(String station, int sec, PreferencesService prefs) {
    final marks = prefs.xprsCatchupMarks;
    if (marks.length >= _marksMax && !marks.containsKey(station)) {
      var oldest = marks.keys.first;
      for (final e in marks.entries) {
        if (e.value < marks[oldest]!) oldest = e.key;
      }
      marks.remove(oldest);
    }
    marks[station] = sec;
    prefs.xprsCatchupMarks = marks;
  }

  // ── Cadence ───────────────────────────────────────────────────────────────
  //
  // Driven from BgService's 2 s native heartbeat, NOT a Dart Timer.periodic: a
  // Dart timer is throttled to near-nothing once Android backgrounds the app
  // (docs/performance.md section 8.2), which is precisely the pocket this poll
  // exists for. MeshService's own 60 s sweep is a bare Timer and used to be
  // what called us, so the poll it drove stopped the moment the screen did.
  String _selfCallsign = '';
  int _lastTickMs = 0;
  bool _ticking = false;
  bool _armed = false;

  /// How often the key binding goes back on air. Section 18.1: "every 30
  /// minutes is a reasonable interval on a quiet channel", because a receiver
  /// that never heard the announcement cannot check a signature. A fresh `ts:`
  /// each period matters — a station dedups an identical wire by its
  /// identifier, so re-airing the same bytes is not a second chance.
  static const Duration identityEvery = Duration(minutes: 30);

  /// The longest this device will go without asking a station it can hear.
  ///
  /// Ten minutes is section 36.10.1's own catch-up cadence and it lands exactly
  /// on section 31.2's ceiling for a caller whose key the station knows -- six
  /// replays an hour. We publish `t:identity` on every bearer, so we are that
  /// caller rather than a stranger metered at two.
  static const Duration askAtLeastEvery = Duration(minutes: 10);
  int _identityAtMs = 0;

  /// Begin polling for [selfCallsign]. Fires once immediately, then settles
  /// into the period — a timer-only poll means a silent first minute
  /// (docs/performance.md section 6.5).
  void start(String selfCallsign) {
    _selfCallsign = selfCallsign;
    if (selfCallsign.isEmpty) return;
    unawaited(_airIdentity());
    unawaited(tick(selfCallsign));
    if (_armed || !Platform.isAndroid) return;
    _armed = true;
    AndroidForegroundService.instance.addTickListener(_onNativeTick);
  }

  void stop() {
    if (!_armed) return;
    _armed = false;
    AndroidForegroundService.instance.removeTickListener(_onNativeTick);
  }

  void _onNativeTick() {
    final now = nowMs();
    // The 2 s heartbeat is shared; this poll only wants a minute of it. tick()
    // enforces the real per-station period on top.
    // The gate below used to be thirty seconds, which quietly made any
    // interval under thirty seconds unreachable however busy a room was. The
    // sweep body is a walk over the stations in reach and returns immediately
    // for every one whose interval has not elapsed, so running it more often
    // costs almost nothing; what it buys is that the fast tier is actually
    // fast (docs/performance.md 4.2 -- cheap checks first, and this is one).
    if (now - _lastTickMs < 5000) return;
    _lastTickMs = now;
    if (_ticking || _selfCallsign.isEmpty) return;
    if (now - _identityAtMs >= identityEvery.inMilliseconds) {
      _identityAtMs = now;
      unawaited(_airIdentity());
    }
    _ticking = true;
    unawaited(tick(_selfCallsign).whenComplete(() => _ticking = false));
  }

  /// When the last sweep ran, how many stations it could see, and when each
  /// was last asked. Reported by /api/status; never logged.
  int _lastSweepMs = 0;
  int _lastSweepSeen = 0;
  Map<String, dynamic> statusJson() => {
        'lastSweepAgoMs': _lastSweepMs == 0 ? null : nowMs() - _lastSweepMs,
        'stationsSeen': _lastSweepSeen,
        // What each archiver has earned, in seconds -- the observable that
        // says whether the cadence is following the room or stuck.
        'intervalS': {
          for (final e in _intervalMs.entries) e.key: e.value ~/ 1000,
        },
        'askedAgoMs': {
          for (final e in _askedAtMs.entries) e.key: nowMs() - e.value,
        },
        'resuming': _resume.keys.toList(),
        // The first-run backfill, because a fresh install that quietly
        // fetches nothing must be readable without a debugger.
        'backfill': {
          'station': _backfillStation,
          'messages': _backfillFetched,
          'target': backfillMessages,
          'days': backfillWindow.inDays,
        },
      };

  /// Test seam: forget every station's news, ask history and pending page.
  /// Singleton, same reason as XprsMonitor.debugReset.
  void debugReset() {
    _askedAtMs.clear();
    _newsSeen.clear();
    _resume.clear();
    _pending.clear();
    _oldestReplayMs.clear();
    _intervalMs.clear();
    _lastNewsMs.clear();
    _inFlight.clear();
    _sawRows.clear();
    _lastResumeMs.clear();
    _identityAtMs = 0;
    _backfillStation = null;
    _backfillFetched = 0;
    _backfillSettled = false;
  }

  /// Announce which key this callsign signs with, on every active bearer.
  /// Section 18.1. Stamped so [start] and the heartbeat share one clock.
  ///
  /// Stamped only when a bearer actually TOOK it. The first tick after boot
  /// reliably beats the radios: on the bench the identity aired into
  /// "ble5:inactive, lan:inactive, reticulum:inactive, lora:inactive" and the
  /// next attempt was thirty minutes out -- half an hour during which nobody
  /// who had not met this station could verify a thing it signed, its mailbox
  /// declaration included. An airing nothing carried is not an airing.
  Future<void> _airIdentity() async {
    _identityAtMs = nowMs();
    try {
      final report = await XprsPublisher.instance.publishIdentity();
      if (!report.values.any((v) => v == 'sent')) {
        _identityAtMs = 0; // nothing took it: retry on the next tick
      }
    } catch (e) {
      LogService.instance.add('XPRS: identity airing failed: $e');
      _identityAtMs = 0;
    }
  }

  /// Driven from the native BgService heartbeat (see [start]) so it keeps
  /// polling with the screen off. Enforces its own period.
  Future<void> tick(String selfCallsign) async {
    final prefs = PreferencesService.instanceSync;
    if (prefs == null || !prefs.xprsCatchup) return;
    if (selfCallsign.isEmpty) return;

    final now = nowMs();
    final periodMs = prefs.xprsCatchupMinutes * 60000;

    // A fresh install has no hole: start keeping from now (36.10.1 rule 2).
    if (prefs.xprsCatchupWatermark == 0) {
      prefs.xprsCatchupWatermark = now ~/ 1000;
      return;
    }

    var anyLocal = false;
    for (final b in XprsPublisher.instance.bearers) {
      if (b.shortRange && await b.active) {
        anyLocal = true;
        break;
      }
    }

    // Every station in DIRECT reach (no via:), fresh within the monitor's own
    // staleness window — a list is a claim about now. No serve:archive filter:
    // any station in earshot may be holding something for us.
    final selfBase = _base(selfCallsign);
    final fresh = anyLocal
        ? (XprsMonitor.instance
            .directlyHeard(nowMs: now)
            .map((c) => XprsMonitor.instance.stations[c])
            .whereType<XprsStation>()
            .where((s) => _base(s.callsign) != selfBase)
            .toList(growable: false))
        : const <XprsStation>[];

    // ── The super-archivers (36.9.4) ────────────────────────────────────
    // A station in earshot holds what IT heard, which is the neighbourhood.
    // Global chat is not a neighbourhood: it is everything everybody said,
    // and the place that holds all of it is a super-archiver on the internet
    // (36.9.4's deep memory). It is asked whether or not any radio is up --
    // that is the whole point of it -- and it is asked the same metered
    // question, on the addressed lane, which is the one the public hubs
    // actually carry (36.12.1).
    //
    // Without this the sweep returned early on a phone with no short-range
    // bearer, and even with one it only ever asked stations it could HEAR --
    // so a network reachable only over the internet was never asked anything,
    // and Global chat arrived from nowhere.
    // The operator's list and the ones heard on the air, in that order. A
    // fresh install has nothing in the first -- which is why it used to ask
    // nobody and show an empty Global chat -- and the second fills itself from
    // whatever announced `serve:…,super` while this device was listening.
    final knownSupers = <String>[];
    for (final c in [
      ...prefs.xprsSuperArchivers,
      // Every station this node has learned from a Reticulum ANNOUNCE.
      //
      // This is the list that makes a fresh install work, and the one that was
      // missing: a phone with no radio neighbour and nothing configured has no
      // heard stations and no named supers, so the sweep returned before
      // asking anybody and Global chat stayed empty with nothing to read
      // anywhere.
      //
      // An announcement is one of only two things a shared transport is
      // guaranteed to carry (36.12.1), and a directed ask is the other -- so
      // between them there is always a way through. Measured on the bench:
      // tank2, installed minutes earlier on a different network, already
      // resolved X3ARK to an LXMF destination two hops away through a public
      // hub. It could have asked at any moment; it just never knew it should.
      ...RnsService.instance.announcedCallsigns(prefix: 'X3'),
    ]) {
      final base = _base(c);
      if (base.isEmpty || base == selfBase) continue;
      if (!knownSupers.contains(base)) knownSupers.add(base);
    }
    // For the ask loop, drop the ones already coming through `fresh` so they
    // are not asked twice. The backfill below uses the FULL list: whether a
    // super also happens to be in earshot says nothing about whether this
    // device is missing a month of what it holds.
    final supers = [
      for (final base in knownSupers)
        if (!fresh.any((s) => _base(s.callsign) == base)) base
    ];
    if (fresh.isEmpty && supers.isEmpty) return;

    // ── The first-run backfill (36.10.1 rule 4's "fetched deliberately") ──
    // A device whose archive holds no conversation has nothing to show in
    // Global chat, and the seven-day poll would fill it a week at a time only
    // as new traffic arrived. Reach back a month instead, once, against one
    // known super, and stop as soon as there is enough to read.
    _updateBackfill(knownSupers, fresh);

    final asked = <String>[];
    for (final st in [
      ...fresh,
      // A super-archiver we have never heard on the air has no station record
      // and so no count:/mail: to compare -- which the news check below reads
      // as "no news", leaving the every-period backstop to carry it.
      for (final c in supers) XprsStation(c, 'rns', now),
    ]) {
      final base = _base(st.callsign);
      // THE NEWS CHECK, and it costs nothing on air: the station's own beacon
      // already says how much it holds (`count:`) and how much mail it is
      // carrying (`mail:`). A replay is metered — six an hour for a caller
      // whose key the station knows, two for a stranger (section 31.2) — so
      // spending one to be told nothing changed is the one thing this poll
      // must not do.
      final news = '${st.count ?? -1}/${st.mail ?? -1}';
      final seen = _newsSeen[base];
      final unfinished = _resume.containsKey(base);
      // The interval this archiver has EARNED. One clock for everybody meant a
      // room silent for three months cost the same metered replay as one with
      // a conversation running; the cadence now follows what the archiver
      // actually returns (xprs_cadence.dart), bounded below by what that peer
      // permits and above by how long it has had nothing to say.
      final wait = _intervalFor(base, prefs, now);
      final quietFor = now - (_askedAtMs[base] ?? 0);
      final overdue = !_askedAtMs.containsKey(base) || quietFor >= wait;

      // The news check ACCELERATES the ask; it must never be the only thing
      // that permits one. A station whose count: we can see is asked the
      // moment it moves; every station is asked at least once a period
      // whatever we think we know.
      //
      // The first version of this made the fallback conditional on the station
      // never having published a count, and that was subtly wrong in exactly
      // the way that matters here: the phone spent twenty minutes on WiFi,
      // learned a count over the LAN, and then went back to BLE where nothing
      // can ever refresh it. `count` was no longer null, so the fallback
      // switched itself off, and the comparison went on succeeding against a
      // number frozen in the past. Stale knowledge is worse than none, because
      // it looks like knowledge. A backstop that is always armed cannot be
      // reasoned out of existence by state going stale.
      if (!overdue && (seen == news) && !unfinished) continue;
      // News accelerates, but never past the floor: the floor is the peer's
      // budget, and a count: that moves every minute does not buy us the right
      // to ask an ordinary archiver every minute.
      final last = _askedAtMs[base] ?? 0;
      final floor = _floorMsFor(base, prefs);
      if (last != 0 && now - last < floor) continue;
      // An ask still waiting for its answer is not a reason to send another.
      // One replay runs at a time on the responder, and a page takes about
      // eighteen seconds to air -- a second ask lands mid-chain and is refused,
      // which under a 429 costs the window rather than shortening it.
      if (_awaiting(base, now)) continue;
      _newsSeen[base] = news;
      _askedAtMs[base] = now;
      _inFlight[base] = now;
      await _ask(selfCallsign, base, now, prefs);
      asked.add(base);
    }
    // One line per sweep, never one per station: this runs every minute for as
    // long as the app lives, into a 2000-line ring (docs/performance.md 3.3).
    if (asked.isNotEmpty) {
      LogService.instance.add('XPRS: polled ${asked.length} station(s) — '
          '${asked.join(", ")}');
    }
    // Silence and "not running" looked identical from outside, which cost an
    // afternoon: a sweep that considers stations and asks none logs nothing,
    // so a stalled poller and a quiet one read the same. This is state, not a
    // log line -- /api/status can answer "when did you last try" without
    // spending a ring entry every thirty seconds.
    _lastSweepMs = now;
    _lastSweepSeen = fresh.length;
  }

  /// How many conversation records the archive holds. The stop condition is
  /// measured from the ARCHIVE, not from the pages served, so a backfill
  /// interrupted by a restart resumes where the device actually is rather
  /// than starting the month again.
  /// Test seam: what the archive holds, when there is no archive to ask.
  @visibleForTesting
  int Function()? messagesHeldOverride;

  int _messagesHeld() {
    final o = messagesHeldOverride;
    if (o != null) return o();
    try {
      // `ready` FIRST: query() answers `const []` when there is no database
      // open, which is indistinguishable from a genuinely empty archive and
      // would arm a month-deep ask on every device that had not finished
      // opening its store yet.
      if (!XprsArchive.instance.ready) return -1;
      // COUNT, not a page. This asked query() for a thousand rows and took
      // their .length -- once a minute, on the main isolate, on a device whose
      // archive is the biggest on the network. See XprsArchive.countOf.
      return XprsArchive.instance.countOf(types: const ['message']);
    } catch (_) {
      // UNKNOWN, which is not the same as empty and must not be treated as
      // it: a month-deep ask is the heaviest thing this poller does, and
      // launching one because the archive happened to be unreadable for a
      // moment spends a peer's metered replay on a question we could not
      // establish we needed to ask. -1 means "do not backfill".
      return -1;
    }
  }

  /// Start, continue or finish the first-run backfill.
  ///
  /// Re-armable on purpose: a first launch that hears no super is not a
  /// permanent verdict, and the next sweep that knows one will pick it up.
  /// Set once this device is known to hold a conversation. The backfill is a
  /// FIRST-RUN job: after that the answer cannot change back, so there is
  /// nothing to re-establish every minute for the life of the process.
  bool _backfillSettled = false;

  void _updateBackfill(List<String> supers, List<XprsStation> fresh) {
    if (_backfillSettled) return;
    final held = _messagesHeld();
    if (held < 0) {
      _backfillStation = null; // cannot read the archive: do not guess
      return;
    }
    _backfillFetched = held;
    if (held >= backfillMessages) {
      _backfillStation = null;
      _backfillSettled = true;
      return;
    }
    if (_backfillStation != null) {
      // Still draining. Keep going while the station is still one we know.
      if (supers.contains(_backfillStation)) return;
      _backfillStation = null;
    }
    // Only a device with NO conversation at all backfills. One that has some
    // is a device the ordinary poll is already serving, and a month-wide ask
    // there is a metered replay spent on records it mostly has.
    if (held > 0) {
      _backfillSettled = true;
      return;
    }
    // A super first -- it is the one that holds everything everybody said.
    // Failing that, a STATION in earshot: `X3` is a station, relay or
    // unattended equipment (section 3), so it keeps a spool worth a month-deep
    // ask. A person's phone is not, which is why the prefix decides rather
    // than mere presence -- asking every neighbour for a month of history
    // would spend somebody's metered replay on a device that has no archive
    // to give.
    if (supers.isNotEmpty) {
      _backfillStation = supers.first;
    } else {
      final station = fresh
          .map((s) => _base(s.callsign))
          .where(_looksLikeStation)
          .firstOrNull;
      if (station == null) return;
      _backfillStation = station;
    }
    LogService.instance.add(
        'XPRS catch-up: first-run backfill from $_backfillStation — '
        'up to $backfillMessages messages or '
        '${backfillWindow.inDays} days');
  }

  /// Is this callsign a station worth asking for history?
  ///
  /// Section 3: `X1` is a person, `X3` is a station, relay or unattended
  /// equipment, `X4` an automated device, `X5` a group. The prefix IS the
  /// indicator -- a station says what it is by its name, so no configuration,
  /// no lookup and no extra round trip is needed to decide it is worth asking.
  /// Whether it is a SUPER is a further claim, carried on its announcement or
  /// answered when asked directly; not knowing that yet is no reason not to
  /// ask, because an archiver with nothing for us answers 404 and costs one
  /// metered packet.
  static bool _looksLikeStation(String call) {
    final c = call.trim().toUpperCase();
    return c.startsWith('X3');
  }

  Future<void> _ask(String self, String archiver, int now,
      PreferencesService prefs) async {
    // since: = THIS station's mark, floored at a week (36.10.1 rule 4). Not a
    // shared one: see PreferencesService.xprsCatchupMarks.
    var sinceSec = _markFor(archiver, prefs);
    final backfilling = archiver == _backfillStation;
    final window = backfilling ? backfillWindow : maxWindow;
    final floorSec = (now - window.inMilliseconds) ~/ 1000;
    if (backfilling) {
      // The mark is IGNORED here, and that is the point of the backfill.
      //
      // A fresh install plants its watermark at the moment it first ticks --
      // "a fresh install has no hole", above -- which is true of this device's
      // own log and false of the conversation. Every later ask then said
      // `since:<the minute it was installed>`, so a new phone could only ever
      // fetch what was said AFTER it arrived, and Global chat opened empty and
      // stayed that way with nothing anywhere reporting a failure. Flooring at
      // the month would not have helped: the mark is NEWER than the floor, so
      // the floor never applied.
      sinceSec = floorSec;
    } else if (sinceSec < floorSec) {
      sinceSec = floorSec;
    }

    // A page the station could not finish: ask for what came BEFORE the oldest
    // record it managed to send, rather than asking the same window again.
    final untilMs = _resume[archiver];

    // `kind:message` because the archive keeps EVERYTHING heard, beacons
    // included, and a page is twelve records newest-first. Measured on the
    // bench: the newest 200 records of a station's archive were 120 t:identity,
    // 69 t:observation, 11 t:service and no messages at all, so an unfiltered
    // page is twelve identity announcements and the conversation is below the
    // fold — one metered replay spent on nothing.
    //
    // NOT `only:`. That is a CALLSIGN (section 36.6), and an earlier version of
    // this line sent a type in it. Against a station that reads only: as a type
    // it happened to work; against one that reads the spec it matched a callsign
    // named MESSAGE, answered 404, and the watermark advanced as though the
    // window were finished.
    // NOT scope:local. It was, and that pinned the ask to the short-range
    // bearers -- which is right for a station across the room and silently
    // wrong for one across the internet: the reticulum bearer refuses a
    // scope:local packet by design (13.11.3), so the peer was never actually
    // asked and its Global chat never arrived. The ask is DIRECTED (d:), so
    // it costs one packet to one station whichever lane carries it, and the
    // answer comes back on the directed lane too (36.12.1).
    final wire = StringBuffer('t:command f:$self d:$archiver ts:${_ts(now)} '
        'cmd:history kind:message since:${_ts(sinceSec * 1000)}');
    if (untilMs != null) wire.write(' until:${_ts(untilMs)}');
    final p = XprsPacket.parse(wire.toString());
    if (p == null || !p.fits) return;

    // Remember the ask so its result can advance the watermark. The id is
    // computed BEFORE signing (section 5 removes sig: anyway, so it is the
    // same id the archiver derives from the signed wire).
    final id = xprsIdentifier(p);
    if (_pending.length >= _pendingMax) _pending.remove(_pending.keys.first);
    _pending[id] = _Ask(archiver, now, partial: untilMs != null);

    final send = sendOverride ?? XprsPublisher.instance.publishWire;
    await send(wire.toString());
  }

  /// Fed every heard t:result (XprsIngest.onResult). Advances the watermark
  /// when the result answers one of our pending asks.
  void onResult(XprsPacket p) {
    final r = p['r'] ?? '';
    final ask = _pending[r];
    if (ask == null) return;
    final code = int.tryParse(p['code'] ?? '') ?? 0;

    // 429 does not answer the window -- the mark stays exactly where it was --
    // but it is NOT nothing, and treating it as silence is what made a refusal
    // free. The archiver is the authority on how often it will answer, so its
    // refusal is the one answer that must always slow this station down;
    // without that, an over-eager poller asks, is refused, and asks again
    // forever, with the window never advancing and the network looking quiet.
    if (code == 429) {
      _pending.remove(r);
      _noteAnswer(ask.station, XprsAnswer.refused);
      LogService.instance.add(
          'XPRS catch-up: ${ask.station} refused (429) — backing off to '
          '${_intervalMs[ask.station]! ~/ 1000}s');
      return;
    }
    if (code != 200 && code != 206 && code != 404) return;
    _pending.remove(r);

    // What the answer was WORTH, which is the whole input to the cadence: an
    // archiver that served rows is talking and is worth coming back to sooner;
    // one that had nothing has just told us it can be left alone longer.
    // Rows we archived while the ask was outstanding, and -- for a 206 -- only
    // if the window actually MOVED. A continuation that comes back to the same
    // place has taught us nothing, however loudly it says there is more, and
    // treating it as news is how a stuck resume loop pins the poller at its
    // fast floor while the room is silent.
    final sawRows = _sawRows.remove(ask.station) ?? false;
    final reached = _oldestReplayMs[ask.station];
    final progressed = code != 206 ||
        reached == null ||
        reached != _lastResumeMs[ask.station];
    if (code == 206 && !progressed) {
      LogService.instance.add(
          'XPRS catch-up: ${ask.station} 206 made no progress at '
          '${_ts(reached!)} — treating as quiet');
    }
    final served = sawRows && progressed;
    _noteAnswer(
        ask.station, served ? XprsAnswer.news : XprsAnswer.quiet);
    final prefs = PreferencesService.instanceSync;
    if (prefs == null) return;

    if (code == 206) {
      // MORE WAS HELD THAN WAS SERVED. Advancing the watermark here — which is
      // what this used to do — declares the whole window done and skips the
      // remainder permanently. Instead remember where the page stopped and ask
      // again with `until:` set to it (section 36.10.1).
      final oldest = _oldestReplayMs[ask.station];
      if (oldest != null) {
        _resume[ask.station] = oldest;
      } else {
        // The station said "more" but we saw none of it — re-ask the same
        // window rather than stepping over it.
        _resume[ask.station] = ask.atMs;
      }
      _newsSeen.remove(ask.station); // there IS more; do not go quiet
      // The peer SAID there is more. Waiting out an interval to be told again
      // is how a backlog takes an afternoon to drain; the next ask is the
      // continuation of this one, so it goes now. The chain-in-flight guard
      // still applies, so this cannot outrun what the archiver can air.
      _askedAtMs.remove(ask.station);
      _lastResumeMs[ask.station] = _resume[ask.station];
      LogService.instance.add(
          'XPRS catch-up: ${ask.station} 206 — resuming before '
          '${_ts(_resume[ask.station]!)}');
      return;
    }

    // 200/404: this window is finished. Only now may the mark move, and only
    // for a full sweep — a continuation answers an older slice and says
    // nothing about the newest.
    _resume.remove(ask.station);
    _oldestReplayMs.remove(ask.station);
    if (ask.station == _backfillStation) {
      // The window is finished, which for a backfill means the month is
      // exhausted -- there is no more to have, however few records it was.
      LogService.instance.add(
          'XPRS catch-up: backfill from ${ask.station} finished with '
          '$_backfillFetched message(s)');
      _backfillStation = null;
    }
    if (ask.partial) return;
    final sec = ask.atMs ~/ 1000;
    if (sec > _markFor(ask.station, prefs)) {
      _setMark(ask.station, sec, prefs);
    }
  }

  /// The oldest replayed record's ts per station, fed by [noteReplay] as the
  /// packets arrive. It is what a `206` continuation asks `until:`.
  final Map<String, int> _oldestReplayMs = {};

  /// A replayed packet arrived from [station]. Called from the ingest funnel
  /// for anything carrying an older ts than now, so a partial page knows where
  /// it stopped.
  /// Rows this archiver actually gave us while an ask was outstanding.
  ///
  /// [noteReplay] cannot answer that question: it is fed from the delivery
  /// hook, which only fires for packets addressed to US. Global chat is a
  /// broadcast, so a pull that returned a hundred messages looked exactly like
  /// one that returned nothing, and the cadence sat pinned at its ceiling
  /// however busy the room was.
  final Map<String, bool> _sawRows = {};

  /// Where the previous continuation for this station reached back to, so a
  /// resume loop that stops moving can be recognised as one.
  final Map<String, int?> _lastResumeMs = {};

  /// How old a packet must be to count as HISTORY rather than live traffic.
  static const Duration _replayAge = Duration(minutes: 1);

  /// A packet from [from], stamped [tsMs], was archived.
  ///
  /// Only rows that answer our ask count, and the timestamp is what tells them
  /// apart: a replayed record keeps its AUTHOR's ts (36.2 -- the archiver
  /// re-airs the original bytes), so history is old by definition while an
  /// announce or a status this station is publishing right now is not. Without
  /// that test every beacon from an archiver we happened to be waiting on
  /// scored as news, and the cadence sat at its fast floor forever -- measured
  /// on the bench: the room went silent and the interval stayed at fifteen
  /// seconds for eight minutes.
  void noteRow(String from, int? tsMs) {
    final base = _base(from);
    if (base.isEmpty || !_inFlight.containsKey(base)) return;
    if (tsMs == null) return;
    if (nowMs() - tsMs < _replayAge.inMilliseconds) return;
    _sawRows[base] = true;
    // Where this page reached back to, which is also what a 206 continuation
    // must ask BEFORE. It was fed only from the delivery hook, and that hook
    // never fires for a broadcast -- so for Global chat the oldest record was
    // always unknown, the continuation fell back to the ask's own ts, and each
    // 206 asked for the same window again. Measured on the bench: the resume
    // mark walked FORWARD with the clock and the backlog never drained.
    final oldest = _oldestReplayMs[base];
    if (oldest == null || tsMs < oldest) _oldestReplayMs[base] = tsMs;
  }

  void noteReplay(String station, int tsMs) {
    final base = _base(station);
    final prev = _oldestReplayMs[base];
    if (prev == null || tsMs < prev) _oldestReplayMs[base] = tsMs;
  }

  static String _base(String c) {
    final i = c.indexOf('-');
    return (i < 0 ? c : c.substring(0, i)).toUpperCase();
  }

  static String _ts(int epochMs) {
    final d = DateTime.fromMillisecondsSinceEpoch(epochMs, isUtc: true);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}_'
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
}


/// One outstanding ask: which station, when we asked, and whether it was a
/// `until:` continuation rather than a full sweep of the window.
class _Ask {
  const _Ask(this.station, this.atMs, {required this.partial});
  final String station;
  final int atMs;
  final bool partial;
}
