/*
 * xprs_profiles: the face and the line a station gives itself (XPRS.md 6.3.2).
 *
 * `t:identity` carries, besides the key binding, a decoration: `nick:`, a
 * picture as `file:<sha>.<ext>` and a description in `m:`. The picture is a
 * reference and not bytes, fetched with `cmd:file` if the receiver wants it.
 * An announcement carries any subset of the fields, and a receiver keeps, per
 * field, the value from the newest verifiable announcement that carried it.
 *
 * This file is both halves, and both are the core's (docs/architecture.md 3):
 *
 *  - OUR picture: a square thumbnail made off the UI isolate, stored in the
 *    media archive like any shared file, named on the profile by its token,
 *    and announced when the profile changes. No wapp and no screen airs it.
 *  - THEIR pictures: decorations offered by the receive door, verified against
 *    the key already held for the callsign, kept newest-per-field, and the
 *    bytes asked for through the one door there is (MediaFetch.want), on a
 *    budget, for the people this station has a reason to see.
 *
 * Screens ask [pictureFor] and listen to [revision]; nothing here draws.
 */
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../profile/profile_service.dart';
import '../../util/media_archive.dart';
import '../../util/media_ref.dart';
import '../background_service.dart';
import '../log_service.dart';
import '../media/media_fetch.dart';
import '../media/media_preview.dart';
import 'xprs_archive.dart';
import 'xprs_groups.dart';
import 'xprs_id.dart';
import 'xprs_packet.dart';
import 'xprs_publisher.dart';
import 'xprs_sig.dart';
import 'xprs_vocab.dart';

/// What one station has said about itself, field by field, each with the
/// `ts:` (ms) of the announcement it came from. A `-` on the wire is kept as
/// null with its time, so an older value cannot come back.
class StationDecoration {
  String? nick;
  int nickTs = 0;
  MediaRef? picture;
  int pictureTs = 0;
  String? about;
  int aboutTs = 0;
}

class XprsProfiles {
  XprsProfiles._();
  static final XprsProfiles instance = XprsProfiles._();

  /// Ticks when a station's decoration changes, or a picture arrives.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  // ── Injected seams (production defaults below; tests replace them) ─────

  /// The key this station holds for a callsign, x-only. Defaults to the
  /// archive's resolver, which RnsService wires to its callsign-to-key map.
  Uint8List? Function(String call)? keyResolver;

  /// The identity rows the archive holds for a callsign, newest first:
  /// `{wire, sig}` maps.
  List<Map<String, dynamic>> Function(String call)? identityRows;

  /// Fetch the bytes of [ref], expected from [from]. Defaults to MediaFetch.
  Future<bool> Function(MediaRef ref, String from)? fetch;

  /// Whether the bytes of [sha] are already here.
  bool Function(String sha)? holds;

  /// Whether [call] is somebody this station has a reason to see without a
  /// screen asking: followed, or a correspondent.
  bool Function(String call)? isKnown;

  /// The stations to ask for [call]'s picture, best first. A person holds
  /// their own; a group (10.1) is a key, not a station, so its picture is
  /// asked of its members, whose roster lists the admin who made it first.
  List<String> Function(String call)? holdersFor;

  /// Publish the NOSTR kind-0 note (name, about, picture). Set by the node,
  /// so this file stays free of it.
  Future<void> Function({String? name, String? about, String? picture})?
      kind0Publisher;

  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  // ── State ───────────────────────────────────────────────────────────────

  static const int _maxStations = 1024;
  final LinkedHashMap<String, StationDecoration> _deco = LinkedHashMap();

  /// Callsigns whose rows were read from the archive, the misses included,
  /// so a station that never decorated itself costs one query, ever.
  final LinkedHashSet<String> _loaded = LinkedHashSet();

  /// Packet identifier to verdict, so a copy heard on a second bearer or a
  /// re-read row costs a lookup and not a curve operation (performance.md
  /// 8.15).
  final LinkedHashMap<String, bool> _verdict = LinkedHashMap();

  int accepted = 0, rejected = 0;

  static String _base(String call) {
    final c = call.trim().toUpperCase();
    final dash = c.indexOf('-');
    return dash < 0 ? c : c.substring(0, dash);
  }

  static bool _decorates(XprsPacket p) =>
      p.type == 'identity' && (p.has('nick') || p.has('file') || p.has('m'));

  /// A `t:identity` that came through the receive door. Only decorations are
  /// of interest; the key binding is the ingest's own business, and it runs
  /// first, so a packet that brings its key is checked against it.
  void offer(String from, XprsPacket p) {
    if (!_decorates(p)) return;
    final call = _base(p['f'] ?? from);
    if (call.isEmpty) return;
    if (_apply(call, p, verify: true)) revision.value++;
  }

  /// A decoration we signed ourselves, for a callsign whose key we hold (a
  /// group we administer, 10.1). Applied without a check, because we just
  /// signed it, and because a station never hears its own packet back.
  void own(String call, XprsPacket p) {
    if (!_decorates(p)) return;
    final c = _base(call);
    if (c.isEmpty) return;
    if (!_loaded.contains(c)) _load(c);
    if (_apply(c, p, verify: false)) revision.value++;
  }

  /// A key for [call] was learned just now: read its decoration again, since
  /// one that arrived before the key could not be checked then.
  void keyLearned(String call) {
    final c = _base(call);
    if (_loaded.remove(c)) {
      _deco.remove(c);
      _verdict.removeWhere((k, v) => !v);
      if (_load(c)) revision.value++;
    }
  }

  StationDecoration? decorationFor(String call) {
    final c = _base(call);
    if (c.isEmpty) return null;
    if (!_loaded.contains(c)) _load(c);
    return _deco[c];
  }

  MediaRef? pictureFor(String call) => decorationFor(call)?.picture;
  String? nickFor(String call) => decorationFor(call)?.nick;
  String? aboutFor(String call) => decorationFor(call)?.about;

  bool _load(String c) {
    _loaded.add(c);
    if (_loaded.length > _maxStations) _loaded.remove(_loaded.first);
    final sw = Stopwatch()..start();
    final rows = (identityRows ?? _archiveRows)(c);
    final queryMs = sw.elapsedMilliseconds;
    if (queryMs >= 100) {
      // Says which step when a screen of avatars is slow: this runs once per
      // station on the UI isolate, inside a widget build.
      LogService.instance.add('perf: profile $c archive read took ${queryMs}ms');
    }
    var changed = false;
    for (final r in rows) {
      final p = XprsPacket.parse('${r['wire'] ?? ''}');
      if (p == null || !_decorates(p)) continue;
      // The archive checked the signature when it stored the row, with the
      // keys it had then. A row it could verify is taken as verified; one it
      // could not is checked now, against whatever key is held today.
      final stored = '${r['sig'] ?? ''}' == XprsSigState.verified.name;
      changed |= _apply(c, p, verify: !stored);
    }
    return changed;
  }

  /// The station's own identity rows, by author. `only:` is the wider 12.6
  /// question (author, addressee or a `hears:` list) and an OR over a scan:
  /// on the C61's archive it cost 1.5 s per station, and a chat list asks for
  /// every row's picture inside its first build, so opening Chat froze the UI
  /// for 12 s. Every row it returned was then dropped unless its author was
  /// `c`, which is exactly what `from:` selects on the author index.
  static List<Map<String, dynamic>> _archiveRows(String c) => [
        for (final r in XprsArchive.instance
            .query(types: const ['identity'], from: c, limit: 8))
          if ('${r['from'] ?? ''}'.toUpperCase() == c) r,
      ];

  bool _verified(XprsPacket p, String call) {
    final id = xprsIdentifier(p);
    final known = _verdict[id];
    if (known != null) return known;
    final key = (keyResolver ?? XprsArchive.instance.keyResolver)?.call(call);
    if (key == null) return false; // not remembered: a key may come later
    final ok = xprsVerify(p, key) == XprsSigState.verified;
    _verdict[id] = ok;
    if (_verdict.length > 512) _verdict.remove(_verdict.keys.first);
    return ok;
  }

  bool _apply(String call, XprsPacket p, {required bool verify}) {
    if (verify && !_verified(p, call)) {
      rejected++;
      return false;
    }
    final ts = xprsParseTs(p['ts']) ?? 0;
    final d = _deco.putIfAbsent(call, StationDecoration.new);
    if (_deco.length > _maxStations) _deco.remove(_deco.keys.first);
    var changed = false;
    final nick = p['nick'];
    if (nick != null && ts > d.nickTs) {
      d.nickTs = ts;
      final v = nick == '-' ? null : nick;
      changed |= v != d.nick;
      d.nick = v;
    }
    final file = p['file'];
    if (file != null && ts > d.pictureTs) {
      d.pictureTs = ts;
      final v = file == '-' ? null : MediaRef.parse('file:$file');
      changed |= v?.sha256 != d.picture?.sha256;
      d.picture = v;
      if (v != null && changed) _prefetch(call, v);
    }
    final m = p['m'];
    if (m != null && ts > d.aboutTs) {
      d.aboutTs = ts;
      final v = m == '-' ? null : m;
      changed |= v != d.about;
      d.about = v;
    }
    if (changed) accepted++;
    return changed;
  }

  // ── Fetching the bytes ──────────────────────────────────────────────────
  //
  // Each fetch is a few dozen packets on a channel other people share. A
  // known station's picture is fetched when it is learned; a stranger's only
  // while a screen is showing them, ten new ones per ten minutes at most. Two
  // at a time, one ask per picture, and a picture that did not come is not
  // asked for again for six hours (performance.md 3.2: cache the miss).

  static const int _inFlightMax = 2;
  static const int _strangerBudget = 10;
  static const Duration _strangerWindow = Duration(minutes: 10);
  static const Duration _missFor = Duration(hours: 6);
  static const Duration _askFor = Duration(minutes: 2);

  final Set<String> _inFlight = {};
  final LinkedHashMap<String, String> _queued = LinkedHashMap(); // sha to call
  final Map<String, int> _missAt = {};
  final List<int> _strangerAsks = [];
  int fetched = 0, missed = 0, strangerAsks = 0;

  /// A screen is showing [call]: get its picture if the budget allows.
  void wantPicture(String call) {
    final c = _base(call);
    final ref = pictureFor(c);
    if (ref == null || _holds(ref.sha256)) return;
    if (!_known(c)) {
      final now = nowMs();
      _strangerAsks.removeWhere(
          (t) => now - t > _strangerWindow.inMilliseconds);
      if (_queued.containsKey(ref.sha256) || _inFlight.contains(ref.sha256)) {
        return;
      }
      if (_strangerAsks.length >= _strangerBudget) return;
      if (!_ask(c, ref)) return;
      _strangerAsks.add(now);
      strangerAsks++;
      return;
    }
    _ask(c, ref);
  }

  void _prefetch(String call, MediaRef ref) {
    if (_known(call)) _ask(call, ref);
  }

  bool _known(String call) =>
      (isKnown ?? _defaultKnown)(call);

  static bool _defaultKnown(String call) {
    // A group whose record we keep is ours: we belong to it or were asked to.
    if (XprsGroups.instance.known.contains(call)) return true;
    final a = XprsArchive.instance;
    if (a.followed.contains(call) || a.followedStations.contains(call)) {
      return true;
    }
    final self = a.selfCallsign;
    return self.isNotEmpty && a.hasExchanged(self, call);
  }

  static const int _groupHolders = 3;

  static List<String> _defaultHolders(String call) {
    if (!call.startsWith('X5')) return [call];
    final me = _base(XprsArchive.instance.selfCallsign);
    return [
      for (final e in XprsGroups.instance.rosterOf(call).roles.entries)
        if (e.key != call &&
            e.key != me &&
            (e.value == XprsRole.member ||
                e.value == XprsRole.mod ||
                e.value == XprsRole.admin))
          e.key,
    ].take(_groupHolders).toList();
  }

  bool _holds(String sha) {
    final h = holds;
    if (h != null) return h(sha);
    return MediaFetch.instance.archive?.call()?.has(sha) ?? false;
  }

  /// Queue a fetch. False when it will not be asked (held, missed lately,
  /// already asked).
  bool _ask(String call, MediaRef ref) {
    final sha = ref.sha256;
    if (_holds(sha) || _inFlight.contains(sha) || _queued.containsKey(sha)) {
      return false;
    }
    final miss = _missAt[sha];
    if (miss != null && nowMs() - miss < _missFor.inMilliseconds) return false;
    _queued[sha] = call;
    if (_queued.length > 32) _queued.remove(_queued.keys.first);
    _pump();
    return true;
  }

  void _pump() {
    while (_inFlight.length < _inFlightMax && _queued.isNotEmpty) {
      final sha = _queued.keys.first;
      final call = _queued.remove(sha)!;
      final ref = pictureFor(call);
      if (ref == null || ref.sha256 != sha) continue;
      _inFlight.add(sha);
      final go = fetch ??
          (MediaRef r, String from) => MediaFetch.instance.want(r, from: from);
      // One holder after another, each on the same clock, until one answers.
      Future<bool> ask(List<String> from) async {
        for (final h in from) {
          final ok = await go(ref, h)
              .timeout(_askFor, onTimeout: () => false)
              .catchError((_) => false);
          if (ok || _holds(sha)) return true;
        }
        return false;
      }
      unawaited(ask((holdersFor ?? _defaultHolders)(call)).then((ok) {
        _inFlight.remove(sha);
        if (ok || _holds(sha)) {
          fetched++;
          revision.value++;
        } else {
          missed++;
          _missAt[sha] = nowMs();
          if (_missAt.length > 256) _missAt.remove(_missAt.keys.first);
        }
        _pump();
      }));
    }
  }

  /// For /api/status. Counters, never a log line per picture.
  Map<String, Object> status() => {
        'stations': _deco.length,
        'accepted': accepted,
        'rejected': rejected,
        'fetched': fetched,
        'missed': missed,
        'strangerAsks': strangerAsks,
        'inFlight': _inFlight.length,
        'queued': _queued.length,
      };

  // ── Our own picture ─────────────────────────────────────────────────────

  MediaArchive? _archive() => MediaFetch.instance.archive?.call();

  /// Turn a picked image into this station's picture: a small square JPEG,
  /// made on a worker and kept in the media archive like any shared file, so
  /// whoever asks for it with `cmd:file` is answered by the same machinery.
  /// Returns its token for the profile's `avatar`, or null when the image
  /// could not be read or nothing small enough came out.
  Future<String?> pictureTokenFor(Uint8List source) async {
    final a = _archive();
    if (a == null) return null;
    Uint8List? thumb;
    try {
      thumb = await BackgroundService.runOffThread(
          () async => MediaPreviews.avatarThumb(source));
    } catch (_) {
      thumb = null;
    }
    if (thumb == null) return null;
    return a.putBytes(thumb, 'jpg', name: 'avatar.jpg');
  }

  /// The bytes of our own picture, if there is one.
  Uint8List? ownPictureBytes() {
    final token = ProfileService.instance.activeProfile?.avatar ?? '';
    final ref = MediaRef.parse(token);
    if (ref == null) return null;
    return _archive()?.get(ref.sha256);
  }

  String _fingerprint = '';
  Timer? _publishSoon;
  bool _started = false;

  /// Watch the active profile: a changed name, picture or description goes
  /// on the air five seconds after the last edit, whichever editor made it.
  /// The first profile seen is not "a change"; the catch-up airs it.
  void start() {
    if (_started) return;
    _started = true;
    _fingerprint = _currentFingerprint();
    ProfileService.instance.revision.addListener(_onProfile);
    unawaited(migrateLegacyAvatar());
  }

  String _currentFingerprint() {
    final p = ProfileService.instance.activeProfile;
    if (p == null) return '';
    return [p.id, p.wireCallsign, p.nickname, p.avatar, p.description]
        .join('\u0001');
  }

  void _onProfile() {
    final f = _currentFingerprint();
    if (f == _fingerprint) return;
    final sameStation = f.split('\u0001').first ==
        _fingerprint.split('\u0001').first;
    _fingerprint = f;
    if (!sameStation) {
      unawaited(migrateLegacyAvatar());
      return;
    }
    _publishSoon?.cancel();
    _publishSoon = Timer(const Duration(seconds: 5), () {
      unawaited(XprsPublisher.instance.publishDecoration());
      unawaited(publishKind0());
    });
  }

  /// A profile from before pictures were files kept its avatar as an image in
  /// its own folder, at whatever size it was picked. Make the thumbnail once,
  /// through the profile's storage (an encrypted profile keeps it inside its
  /// container), and name it on the profile. The original stays where it is.
  Future<void> migrateLegacyAvatar() async {
    final p = ProfileService.instance.activeProfile;
    if (p == null || p.avatar.isEmpty || p.avatar.startsWith('file:')) return;
    try {
      final bytes =
          await ProfileService.instance.storageForProfile(p.id).readBytes(p.avatar);
      if (bytes == null || bytes.isEmpty) return;
      final token = await pictureTokenFor(bytes);
      if (token == null) return;
      final now = ProfileService.instance.activeProfile;
      if (now == null || now.id != p.id || now.avatar != p.avatar) return;
      await ProfileService.instance.update(now.copyWith(avatar: token));
      LogService.instance.add('XPRS: profile picture moved to the media store');
    } catch (e) {
      LogService.instance.add('XPRS: profile picture not migrated ($e)');
    }
  }

  /// The NOSTR kind-0 note, for NOSTR clients that will never read a
  /// `t:identity`: the same name, description and thumbnail, inline.
  Future<void> publishKind0() async {
    final pub = kind0Publisher;
    final p = ProfileService.instance.activeProfile;
    if (pub == null || p == null) return;
    final bytes = ownPictureBytes();
    await pub(
      name: p.nickname,
      about: p.description,
      picture: bytes == null ? null : 'data:image/jpeg;base64,${base64Encode(bytes)}',
    );
  }
}
