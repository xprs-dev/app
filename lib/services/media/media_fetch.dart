/*
 * media_fetch — the one door the core opens to get the bytes behind a file:
 * reference, whoever wants them.
 *
 * A `file:<sha>.<ext>` reference is location-independent (XPRS.md §7.7): the
 * bytes may be a packet-lane away over a public hub, a bulk transfer over a
 * link, or on a torrent swarm, and any holder satisfies the reference. Which
 * lane to take is a transport decision, and transport decisions are the core's
 * (docs/architecture.md §3). So every caller — the chat render, a wapp's
 * `hal_media_fetch`, the remote API, a tap on a thumbnail — asks HERE, and this
 * decides:
 *
 *   1. Already held?            → done, re-use (the cheapest answer).
 *   2. Packet-lane sized (≤32 kB, or unknown)? → ask the holder for the whole
 *      file over §7.7.6, which is the ONLY lane that crosses a public hub, and
 *      race the internet ladder.
 *   3. Larger, and a link or an internet path reaches the holder, within the
 *      operator's ceiling → the bulk lane (cmd:file) racing the internet ladder.
 *   4. Larger, reachable only over a shared radio (BLE/LoRa) → WAIT for a tap:
 *      a photo over BLE jams the channel for everyone (operator's rule).
 *
 * Progress is unified across the three lanes into one reading, and completion —
 * whichever lane wins — is one event, because every lane ends in
 * [MediaArchive.putBytes] and [MediaArchive.onPut] is the single place that
 * fires. A wapp learns the state through `hal_media_state` and the `core.media`
 * topic; the host UI listens to [events]. Neither polls.
 *
 * This names no wapp and holds no bytes of its own (docs/architecture.md).
 */
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../util/media_archive.dart';
import '../../util/media_ref.dart';
import '../event_bus.dart';
import '../preferences_service.dart';
import '../receive/core_state.dart';
import '../reticulum/rns_service.dart';
import '../xprs/xprs_files.dart';
import '../xprs/xprs_inline_file.dart';
import '../xprs/xprs_lan.dart';
import '../xprs/xprs_publisher.dart';
import '../xprs/xprs_vocab.dart';
import 'media_ref_index.dart';

/// The largest file a conversation will take into the archive.
///
/// Attaching copies the bytes into a database blob, so the ceiling is what a
/// phone can hold in memory once, for one deliberate user action. Anything
/// bigger is shared from a folder, where the bulk lane streams it off disk
/// (docs/performance.md §8.9).
const int kMediaPutMaxBytes = 16 * 1024 * 1024;

/// Where the bytes of a referenced file are, right now.
enum MediaState { absent, seeking, fetching, ready, failed }

/// What lane [MediaFetch.decide] chose for a request.
enum MediaLane { packet, bulkAndInternet, internetOnly, wait }

/// A reading of one file's fetch, for a progress bar.
class MediaProgress {
  const MediaProgress(this.state, {this.received = 0, this.total = 0, this.lane});
  final MediaState state;
  final int received;
  final int total;
  final String? lane;
}

/// Fired when a file's fetch state moves (host-side listeners; the wapp side
/// is the coalesced `core.media` topic instead).
class MediaEvent extends AppEvent {
  MediaEvent(this.sha, this.state);
  final String sha; // 43-char base64url
  final MediaState state;
}

class MediaFetch {
  MediaFetch._();
  static final MediaFetch instance = MediaFetch._();

  /// The device's shared archive (bytes + `has`/`getMeta`). Injected by the
  /// core so this file needs no path knowledge and tests pass a temp one.
  MediaArchive? Function()? archive;

  /// This station's callsign, for the `f:` on a `cmd:file` ask. Injected.
  String Function()? selfCallsign;

  /// The internet resolution ladder (RNS content fetch → LAN Blossom → I2P →
  /// torrent, re-seed on success). Injected so the core does not reach into
  /// the wapp layer where the ladder currently lives. Returns true when the
  /// bytes are in the archive afterwards.
  Future<bool> Function(String sha, String ext, {String? from})? internetResolve;

  final Map<String, Completer<bool>> _inflight = {};
  final Map<String, MediaState> _state = {};

  final _events = StreamController<MediaEvent>.broadcast();
  Stream<MediaEvent> get events => _events.stream;

  int served = 0; // re-use hits
  int fetched = 0; // downloads that completed

  /// The archive's [MediaArchive.onPut] target: bytes landed for [sha],
  /// whichever lane brought them. Completes any waiter and tells listeners.
  /// The core wires `mediaArchive.onPut = MediaFetch.instance.notePut`.
  void notePut(String sha, int size, String ext) {
    _state[sha] = MediaState.ready;
    final w = _inflight.remove(sha);
    if (w != null && !w.isCompleted) {
      fetched++;
      w.complete(true);
    }
    _emit(sha, MediaState.ready);
  }

  /// The lane for a file of [size] bytes, given whether a link/internet path
  /// reaches the holder ([link]), whether the only way to it is a shared radio
  /// ([bleOnly]), the operator's auto ceiling ([maxMb], 0 = never auto), and
  /// whether the user asked for it explicitly ([userTapped]). Pure; the whole
  /// policy in one testable place.
  static MediaLane decide({
    required int? size,
    required bool link,
    required bool bleOnly,
    required int maxMb,
    required bool userTapped,
  }) {
    // Unknown size is treated as packet-lane-sized: the holder's 202/404 to a
    // `have:AA` ask bounds it (the server refuses `have:` above the cap), so a
    // wrong guess costs one small ask, never a large unasked transfer.
    if (size == null || size <= kInlineMaxBytes) return MediaLane.packet;
    final withinCeiling = maxMb > 0 && size <= maxMb * 1024 * 1024;
    if (userTapped) {
      return link ? MediaLane.bulkAndInternet : MediaLane.internetOnly;
    }
    // A shared radio is the only way there: never spend it on a large file
    // unasked — it jams the channel for everyone.
    if (bleOnly) return MediaLane.wait;
    if (link && withinCeiling) return MediaLane.bulkAndInternet;
    if (!link && withinCeiling) return MediaLane.internetOnly;
    return MediaLane.wait;
  }

  /// Get the bytes for [ref], for a message [from] a callsign, of [size] bytes
  /// (null unknown). [userTapped] lifts the auto-fetch ceilings. Completes true
  /// when the file is in the archive. Idempotent per sha: a second call while
  /// the first is in flight returns the same future, and one already held
  /// returns at once.
  Future<bool> want(MediaRef ref, {String? from, int? size, bool userTapped = false}) {
    final a = archive?.call();
    if (a == null) return Future.value(false);
    final sha = ref.sha256;
    if (a.has(sha)) {
      _state[sha] = MediaState.ready;
      served++;
      return Future.value(true);
    }
    final existing = _inflight[sha];
    if (existing != null) {
      // One request per hash, and one completer — but a PERSON tapping again
      // is not a duplicate, it is "try again". The asks are idempotent (a
      // `cmd:file` the holder already answered costs one packet) and the
      // holder may have become reachable, or the file may have been advertised,
      // since the first attempt. Without this the first tap owned the hash for
      // half an hour and every later tap was silently dropped on the floor.
      if (userTapped) _runLanes(ref, from, size, userTapped: true);
      return existing.future;
    }

    // Fill an unknown size and an unknown holder from what the message said
    // (the index), so the lane choice is right even when the caller did not
    // pass them. A tap on a thumbnail knows the hash and rarely knows who
    // shared it; without this, the one lane that can always answer — asking
    // the sender — was the one lane a tap could not use.
    final said = MediaRefIndex.instance.describe(sha);
    size ??= said?.size;
    if ((from == null || from.isEmpty) && (said?.from ?? '').isNotEmpty) {
      from = said!.from;
    }

    final link = (from != null && from.isNotEmpty &&
            RnsService.instance.reachableByCallsign(from)) ||
        XprsLan.instance.peerCount > 0;
    final lanes = (from == null || from.isEmpty)
        ? const <String>{}
        : XprsPublisher.instance.reachableLanes(from);
    final bleOnly = lanes.contains('ble5') && !lanes.contains('reticulum') &&
        XprsLan.instance.peerCount == 0;
    final maxMb = PreferencesService.instanceSync?.mediaAutoMaxMb ?? 10;
    final lane = decide(
        size: size, link: link, bleOnly: bleOnly, maxMb: maxMb, userTapped: userTapped);

    if (lane == MediaLane.wait) {
      _state[sha] = MediaState.absent;
      return Future.value(false);
    }

    final done = Completer<bool>();
    _inflight[sha] = done;
    _state[sha] = MediaState.seeking;
    _emit(sha, MediaState.seeking);

    // Every lane below lands bytes via putBytes → onPut, which is what
    // completes `done`. A lane that fails on its own (404, ladder false) does
    // NOT complete it — a slower lane may still win — so a timeout guards the
    // whole request.
    _runLanes(ref, from, size, userTapped: userTapped, lane: lane);

    Timer(const Duration(minutes: 30), () {
      final w = _inflight.remove(sha);
      if (w != null && !w.isCompleted) {
        _state[sha] = a.has(sha) ? MediaState.ready : MediaState.failed;
        _emit(sha, _state[sha]!);
        w.complete(a.has(sha));
      }
    });
    return done.future;
  }

  /// Set every lane [decide] chose going. Separate from [want] because a
  /// person tapping a picture that is already being fetched is asking for
  /// another attempt, not for a second transfer: the asks repeat, the
  /// completer does not.
  void _runLanes(MediaRef ref, String? from, int? size,
      {required bool userTapped, MediaLane? lane}) {
    final chosen = lane ??
        decide(
            size: size ?? MediaRefIndex.instance.describe(ref.sha256)?.size,
            link: (from != null && from.isNotEmpty &&
                    RnsService.instance.reachableByCallsign(from)) ||
                XprsLan.instance.peerCount > 0,
            bleOnly: false,
            maxMb: PreferencesService.instanceSync?.mediaAutoMaxMb ?? 10,
            userTapped: userTapped);
    switch (chosen) {
      case MediaLane.packet:
        _askPacketLane(ref, from);
        _runInternet(ref, from);
      case MediaLane.bulkAndInternet:
        _askBulkLane(ref, from);
        _runInternet(ref, from);
      case MediaLane.internetOnly:
        _runInternet(ref, from);
      case MediaLane.wait:
        break;
    }
  }

  /// Ask the holder to send the whole file over the packet lane: a `cmd:file`
  /// carrying `have:AA` (an all-zero map = "I have nothing, send everything",
  /// §7.7.6/§8.1). Signed by the publisher, which the holder's audience gate
  /// requires. No-op without a holder callsign or a self callsign.
  void _askPacketLane(MediaRef ref, String? from) {
    final self = selfCallsign?.call().trim().toUpperCase() ?? '';
    final dest = (from ?? '').trim().toUpperCase();
    if (self.isEmpty || dest.isEmpty) return;
    final wire = 't:command f:$self d:$dest ts:${xprsNowTs()} '
        'cmd:file file:${ref.token.substring(5)} have:AA';
    unawaited(XprsPublisher.instance.publishWire(wire));
  }

  /// The bulk lane: a directed `cmd:file` that XprsFileFetch brackets, racing
  /// its own internet middle. Needs a holder callsign.
  void _askBulkLane(MediaRef ref, String? from) {
    final self = selfCallsign?.call().trim().toUpperCase() ?? '';
    final dest = (from ?? '').trim().toUpperCase();
    if (self.isEmpty || dest.isEmpty) return;
    unawaited(XprsFileFetch.instance.fetch(
      archiver: dest,
      shaHex: ref.sha256Hex,
      selfCallsign: self,
      ext: ref.ext,
    ));
  }

  void _runInternet(MediaRef ref, String? from) {
    final r = internetResolve;
    if (r == null) return;
    final sha = ref.sha256;
    if (_state[sha] == MediaState.seeking) {
      _state[sha] = MediaState.fetching;
      _emit(sha, MediaState.fetching);
    }
    unawaited(r(ref.sha256, ref.ext, from: from).catchError((_) => false));
  }

  /// A reading for [shaOrRef] (43-char base64url, hex, a token, or `<sha>.<ext>`).
  MediaProgress progress(String shaOrRef) {
    final sha = _shaOf(shaOrRef);
    final a = archive?.call();
    if (a != null && a.has(sha)) return const MediaProgress(MediaState.ready);
    // Byte progress, first lane that reports.
    final inline = XprsInlineAsm.instance.progressOf(sha);
    if (inline != null) {
      return MediaProgress(MediaState.fetching,
          received: inline.received, total: inline.total, lane: 'packet');
    }
    final shaBytes = _sha32(sha);
    if (shaBytes != null) {
      final rns = RnsService.instance.fileFetchProgress(shaBytes);
      if (rns != null && rns.received > 0) {
        final total = rns.total > 0 ? rns.total : (MediaRefIndex.instance.describe(sha)?.size ?? 0);
        return MediaProgress(MediaState.fetching,
            received: rns.received, total: total, lane: 'internet');
      }
    }
    final st = _state[sha] ?? MediaState.absent;
    return MediaProgress(st,
        total: MediaRefIndex.instance.describe(sha)?.size ?? 0);
  }

  /// What the message said about a hash (size, name, the original a preview
  /// stands for). Thin pass-through to the index, so callers have one place.
  MediaRefInfo? describe(String sha) => MediaRefIndex.instance.describe(sha);
  MediaRefInfo? originalOf(String previewSha) =>
      MediaRefIndex.instance.originalOf(previewSha);

  void _emit(String sha, MediaState st) {
    if (!_events.isClosed) _events.add(MediaEvent(sha, st));
    EventBus().fire(MediaEvent(sha, st));
    CoreState.instance.changed(CoreState.media);
  }

  static String _shaOf(String s) {
    var v = s.startsWith('file:') ? s.substring(5) : s;
    if (v.contains('.')) v = v.substring(0, v.indexOf('.'));
    if (v.length == 64) return MediaRef.hexToB64u(v) ?? v;
    return v;
  }

  static Uint8List? _sha32(String b64u) {
    try {
      final pad = (4 - b64u.length % 4) % 4;
      final b = base64Url.decode(b64u + ('=' * pad));
      return b.length == 32 ? b : null;
    } catch (_) {
      return null;
    }
  }
}
