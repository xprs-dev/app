// =============================================================================
// update_mirror_service.dart — an always-on station mirrors app releases so the
// phones around it can update without reaching the internet for the binary.
//
// The web announces, Reticulum carries. The xprs.dev feed is a ~1 KB document
// naming the newest version and, per artifact, its size, its download URL and
// its sha256. This service is the only participant that uses that URL: it
// downloads each artifact once, verifies it, and drops it into a signed
// Reticulum folder it owns. The folder's disk sync then publishes a DHT
// provider record keyed on each file's sha256 — the same sha256 the feed
// already told every phone. So an ordinary phone fetches the bytes by content
// address from here, and never makes an HTTPS request for an APK.
//
// Opt-in, and off by default: an ordinary phone must not spend a byte on this.
//
// Memory is the whole design constraint. An artifact is 47-61 MB and the
// station is the device under the most pressure (see docs/performance.md 8.7):
//   - the download is handed to the system DownloadManager, which streams to
//     disk in its own process — nothing enters the Dart heap;
//   - verification hashes in 64 KiB chunks on a worker isolate;
//   - pruning reads FILENAMES, never bytes and never a folder browse.
// =============================================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'background_service.dart';
import 'log_service.dart';
import 'preferences_service.dart';
import 'reticulum/rns_service.dart';
import 'update_models.dart';
import 'update_native.dart';
import 'xprs/xprs_files.dart';
import 'update_service.dart';

class UpdateMirrorService extends BackgroundService {
  UpdateMirrorService._()
      : super(
          id: 'update.mirror',
          name: 'Update mirror',
          interval: pollInterval,
          description: 'Mirrors XPRS release artifacts from the update feed '
              'into signed Reticulum folders this station seeds.',
        );

  static final UpdateMirrorService instance = UpdateMirrorService._();

  /// Six hours (docs/performance.md 6.5 — a poll interval is a battery
  /// setting). Releases ship at most weekly, and nobody is awake to see the
  /// result: what a tick produces is bytes on a disk that some phone will ask
  /// for hours or days later. Anything faster is heat. One tick fires
  /// immediately at start, then it settles.
  static const Duration pollInterval = Duration(hours: 6);

  /// Newest N versions kept per channel. Older ones leave the disk and, via the
  /// folder differ, the signed folder too.
  static const int keepPerChannel = 5;

  /// How often a running download is polled. Deliberately not the Update
  /// Center's 700 ms: no one is watching a progress bar on a station, and this
  /// cuts the platform-channel traffic by 7x.
  static const Duration _pollDownload = Duration(seconds: 5);

  /// A download that has not finished in this long is abandoned; the next tick
  /// starts it again. Bounds a stuck job instead of holding the tick forever.
  static const Duration _downloadDeadline = Duration(minutes: 30);

  static const _kStableFolder = 'update.mirror.folder.stable';
  static const _kBetaFolder = 'update.mirror.folder.beta';

  String? stableFolderId;
  String? betaFolderId;
  String? stableDir;
  String? betaDir;
  int lastPollMs = 0;
  int lastAddMs = 0;
  String? lastError;
  final Map<String, int> _inFlight = {}; // artifact name -> percent

  // Folder creation needs the Reticulum folder manager, which comes up later
  // than main(). Bounded short retries so a boot-order race costs minutes
  // rather than the six hours until the next tick.
  static const Duration _folderRetryDelay = Duration(minutes: 2);
  static const int _maxFolderRetries = 10;
  Timer? _folderRetry;
  int _folderRetries = 0;

  /// One tick at a time. A tick can run for minutes (ten artifacts, ~460 MB),
  /// and the immediate tick from onStart plus a retry timer were able to
  /// overlap and race each other over folder creation.
  bool _ticking = false;

  /// Per-channel summary, refreshed on tick from the one directory pass the
  /// prune already does. Cached so a curious `curl` in a loop is not a
  /// directory walk in a loop.
  final Map<String, Map<String, dynamic>> _held = {};

  // ── test seams (the messagesHeldOverride idiom from xprs_catchup.dart) ──
  Future<ReleaseInfo?> Function(String channelFile)? feedOverride;
  List<String> Function(String dir)? heldNamesOverride;
  Future<String?> Function(ReleaseAsset a, String version)? fetchOverride;
  Future<void> Function(String path)? deleteOverride;

  bool get enabled =>
      PreferencesService.instanceSync?.updateMirrorEnabled ?? false;

  @override
  Future<void> onStart() async {
    if (!enabled) return;
    // Respects the F-Droid kill switch: a build that may not self-update must
    // not mirror updates for anyone else either.
    if (!UpdateService.instance.supported) {
      lastError = 'self-update disabled in this build';
      return;
    }
    await UpdateService.instance.load();
    final p = await SharedPreferences.getInstance();
    stableFolderId = p.getString(_kStableFolder);
    betaFolderId = p.getString(_kBetaFolder);
    await _ensureFolders(p);
    // Answer `cmd:file` for anything we hold. The artifacts are already on
    // disk, already verified, and already keyed by the sha256 the feed
    // published — which is the same digest a peer will ask for.
    XprsFileServer.instance.resolver = heldFile;
    for (final d in [stableDir, betaDir]) {
      if (d != null) _loadDigests(d);
    }
    unawaited(tickNow()); // don't wait six hours to do the first thing
  }

  /// The `cmd:file` resolver: does either channel directory hold this digest?
  ///
  /// Reads the directory, never the files. The name carries the version and the
  /// platform, but identity is the digest, so the lookup is by content: a peer
  /// that asks for a sha we have gets it whatever the file happens to be called.
  XprsHeldFile? heldFile(String shaHex) {
    for (final dir in [betaDir, stableDir]) {
      if (dir == null) continue;
      for (final name in _heldNames(dir)) {
        final path = '$dir${Platform.pathSeparator}$name';
        if (_shaOfHeld(path) != shaHex) continue;
        final len = File(path).lengthSync();
        final dot = name.lastIndexOf('.');
        return XprsHeldFile(
          path: path,
          shaHex: shaHex,
          size: len,
          name: name,
          ext: dot > 0 ? name.substring(dot + 1) : '',
        );
      }
    }
    return null;
  }

  /// Digest of an artifact we hold, from the manifest the mirror keeps beside
  /// the files — never by hashing 56 MB to answer a question.
  ///
  /// The map is also written to `.digests.json` in each channel directory,
  /// because an in-memory one is empty after a restart and stays empty until
  /// the next six-hourly tick. A peer that asked in that window got a `404`
  /// for a file sitting right there — observed on the bench.
  final Map<String, String> _shaByPath = {};

  static const String _digestFile = '.digests.json';

  String? _shaOfHeld(String path) {
    final known = _shaByPath[path];
    if (known != null) return known;
    // Not in memory: consult the manifest of the directory it is in.
    final sep = path.lastIndexOf(Platform.pathSeparator);
    if (sep <= 0) return null;
    _loadDigests(path.substring(0, sep));
    return _shaByPath[path];
  }

  /// Read a channel's digest manifest into the map. Cheap: a few hundred bytes.
  void _loadDigests(String dir) {
    try {
      final f = File('$dir${Platform.pathSeparator}$_digestFile');
      if (!f.existsSync()) return;
      final m = jsonDecode(f.readAsStringSync());
      if (m is! Map) return;
      for (final e in m.entries) {
        _shaByPath['$dir${Platform.pathSeparator}${e.key}'] =
            '${e.value}'.toLowerCase();
      }
    } catch (_) {}
  }

  /// Write what we know about [dir] back to its manifest.
  void _saveDigests(String dir) {
    try {
      final prefix = '$dir${Platform.pathSeparator}';
      final out = <String, String>{};
      for (final e in _shaByPath.entries) {
        if (!e.key.startsWith(prefix)) continue;
        out[e.key.substring(prefix.length)] = e.value;
      }
      if (out.isEmpty) return;
      File('$prefix$_digestFile').writeAsStringSync(jsonEncode(out));
    } catch (e) {
      lastError = 'digest manifest: $e';
    }
  }

  /// Create (or re-adopt) the two disk-backed folders this station owns.
  ///
  /// The master key lives in `<dir>/.folder.json`, written by the folder
  /// manager, so `folderAddFromDisk` on an existing directory returns the SAME
  /// folder id — the id survives a reinstall as long as the directory does. The
  /// prefs copy is a cache for the status endpoint, never the source of truth.
  Future<void> _ensureFolders(SharedPreferences p) async {
    final base = await _baseDir();
    if (base == null) {
      lastError = 'no writable directory for the mirror';
      return;
    }
    for (final ch in const ['stable', 'beta']) {
      final dir = Directory('$base/$ch');
      try {
        if (!dir.existsSync()) dir.createSync(recursive: true);
      } catch (e) {
        lastError = 'cannot create $ch dir: $e';
        continue;
      }
      // The DIRECTORY is what serving a file needs, and it is ours the moment
      // it exists. Set it before the Reticulum folder, which is a different
      // lane and may fail or lag: answering `cmd:file` with a 404 for an
      // artifact sitting right there, because a folder id had not come back
      // yet, is exactly what happened on the bench (notHeld 2 with the file on
      // disk and its digest in the manifest).
      if (ch == 'stable') {
        stableDir = dir.path;
      } else {
        betaDir = dir.path;
      }
      _loadDigests(dir.path);

      final id = await RnsService.instance.folderAddFromDisk(dir.path);
      if (id == null) {
        lastError = 'folderAddFromDisk failed for $ch';
        continue;
      }
      if (ch == 'stable') {
        stableFolderId = id;
        await p.setString(_kStableFolder, id);
      } else {
        betaFolderId = id;
        await p.setString(_kBetaFolder, id);
      }
      LogService.instance.add('update-mirror: $ch folder $id at ${dir.path}');
    }
  }

  /// The mirror's own root, deliberately OUTSIDE the folder download root: a
  /// directory under that root would be adopted a second time by the folder
  /// manager's own scan and published twice.
  ///
  /// Kept on the same volume as the DownloadManager destination so moving a
  /// finished artifact in is a rename (a metadata op) and not a 61 MB copy.
  Future<String?> _baseDir() async {
    try {
      if (Platform.isAndroid) {
        final ext = await UpdateNative.externalFilesDir();
        if (ext != null && ext.isNotEmpty) return '$ext/update-mirror';
      }
      final sup = await UpdateNative.supportDir();
      if (sup != null) return '$sup/mirror';
    } catch (e) {
      lastError = '$e';
    }
    return null;
  }

  @override
  Future<void> onStop() async {
    _folderRetry?.cancel();
    _folderRetry = null;
  }

  @override
  Future<void> onTick() async {
    if (!enabled || _ticking) return;
    _ticking = true;
    try {
      await _tick();
    } finally {
      _ticking = false;
    }
  }

  Future<void> _tick() async {
    lastPollMs = DateTime.now().millisecondsSinceEpoch;
    // Folders may not have been creatable at start: the folder manager comes up
    // with Reticulum, which is later than main(). Retry here rather than let a
    // boot-order race cost six hours.
    if (stableFolderId == null || betaFolderId == null) {
      await _ensureFolders(await SharedPreferences.getInstance());
      if (stableFolderId == null || betaFolderId == null) {
        // Still not up. Come back in a couple of minutes rather than at the
        // next six-hour tick — but only while this is actually the problem, so
        // a station with no Reticulum at all is not retrying forever.
        if (_folderRetries < _maxFolderRetries) {
          _folderRetries++;
          _folderRetry?.cancel();
          _folderRetry = Timer(_folderRetryDelay, () {
            if (isRunning) unawaited(tickNow());
          });
        }
        return;
      }
      _folderRetries = 0;
      lastError = null; // the retry worked; stop reporting the old failure
    }
    try {
      await _mirrorChannel('stable.json',
          dir: stableDir, folderId: stableFolderId, prereleaseOk: false);
      await _mirrorChannel('beta.json',
          dir: betaDir, folderId: betaFolderId, prereleaseOk: true);
      lastError = null;
    } catch (e) {
      lastError = '$e';
      LogService.instance.add('update-mirror: tick failed: $e');
    } finally {
      // Report what is on disk whatever happened above: a channel that threw
      // half way is exactly the one an operator needs to see the contents of.
      if (stableDir != null) _refreshHeld('stable', stableDir!);
      if (betaDir != null) _refreshHeld('beta', betaDir!);
    }
  }

  Future<void> _mirrorChannel(
    String channelFile, {
    required String? dir,
    required String? folderId,
    required bool prereleaseOk,
  }) async {
    if (dir == null || folderId == null) return;
    final rel = feedOverride != null
        ? await feedOverride!(channelFile)
        : await UpdateService.instance.releaseFromFeed(channelFile,
            prereleaseOk: prereleaseOk);
    if (rel == null || rel.version.isEmpty) return;

    // Names only. Never a folder browse to find out what we hold: that reduces
    // and re-verifies the whole signed op-log to answer a question the
    // filesystem answers for free (arch_guard no-page-fetch-to-count).
    final held = _heldNames(dir).toSet();
    var added = 0;
    for (final a in rel.assets) {
      if (a.name.isEmpty || a.sha256.isEmpty) continue;
      final target = mirrorFileName(a.name, rel.version);
      // Learn the digest of everything this channel names, held or not. The
      // feed is where a sha comes from; hashing an artifact we already
      // verified once, to answer "do you hold this?", would be the expensive
      // way to know something we were told.
      _shaByPath['$dir${Platform.pathSeparator}$target'] =
          a.sha256.toLowerCase();
      if (held.contains(target)) continue;
      if (await _ingest(a, target, rel.version, dir, folderId)) added++;
    }
    if (added > 0) {
      lastAddMs = DateTime.now().millisecondsSinceEpoch;
      LogService.instance
          .add('update-mirror: $channelFile +$added artifact(s) ${rel.version}');
    }
    await _prune(dir, folderId);
    _saveDigests(dir);
  }

  List<String> _heldNames(String dir) {
    if (heldNamesOverride != null) return heldNamesOverride!(dir);
    try {
      // Non-recursive, filenames only — the dir holds ~20 flat files.
      return Directory(dir)
          .listSync(followLinks: false)
          .whereType<File>()
          .map((f) => f.path.split(Platform.pathSeparator).last)
          .where((n) => !n.startsWith('.'))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Download one artifact, verify it, and publish it by moving it in.
  ///
  /// Returns true when the artifact is now in the folder. Every failure path
  /// leaves NOTHING behind in [dir]: a corrupt or partial artifact that reached
  /// the folder would be signed, announced and served to every phone.
  Future<bool> _ingest(ReleaseAsset a, String target, String version,
      String dir, String folderId) async {
    final staged = fetchOverride != null
        ? await fetchOverride!(a, version)
        : await _fetch(a, version);
    if (staged == null) return false;

    final ok = await UpdateNative.verifyFile(staged,
        expectedSize: a.size, expectedSha: a.sha256);
    if (!ok) {
      LogService.instance
          .add('update-mirror: ${a.name} failed verification, discarded');
      await _delete(staged);
      return false;
    }
    try {
      // Rename, not copy: same volume, so this is atomic and costs no bytes.
      // It also means the folder differ can never observe a half-written APK —
      // the file appears complete or not at all.
      await File(staged).rename('$dir${Platform.pathSeparator}$target');
    } catch (e) {
      LogService.instance.add('update-mirror: ${a.name} move failed: $e');
      await _delete(staged);
      return false;
    }
    // The differ picks this up within its own 60 s sweep anyway; asking now
    // makes the artifact fetchable in seconds instead of a minute.
    unawaited(RnsService.instance.folderRescan(folderId));
    return true;
  }

  /// Hand the URL to the system DownloadManager and wait for it. The bytes go
  /// process-to-disk; this function only ever holds the path.
  Future<String?> _fetch(ReleaseAsset a, String version) async {
    if (!UpdateNative.hasDownloadManager) {
      // Desktop station: UpdateNative.download streams through an IOSink and
      // rejects a truncated transfer itself.
      return UpdateNative.download(a.url, a.name, (_, _) {});
    }
    final id =
        await UpdateNative.enqueueDownload(a.url, a.name, 'Mirroring $version');
    if (id == null) {
      // On a headless engine this used to be the silent failure: the channel
      // did not exist, the exception was swallowed and null came back forever.
      // UpdateBridge now attaches it on every engine, so a null here is a real
      // DownloadManager refusal and worth a line.
      LogService.instance.add('update-mirror: enqueue refused for ${a.name}');
      return null;
    }
    final deadline = DateTime.now().add(_downloadDeadline);
    try {
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(_pollDownload);
        final r = await UpdateNative.pollDownload(id);
        final status = '${r['status']}';
        final total = (r['total'] as num?)?.toInt() ?? 0;
        final got = (r['downloaded'] as num?)?.toInt() ?? 0;
        _inFlight[a.name] = total > 0 ? (got * 100 ~/ total) : 0;
        if (status == 'success') {
          final path = r['localPath'] as String?;
          if (path != null && path.isNotEmpty) return path;
          return null;
        }
        if (status == 'failed' || status == 'unknown') {
          LogService.instance
              .add('update-mirror: ${a.name} download $status (${r['reason']})');
          return null;
        }
      }
      LogService.instance.add('update-mirror: ${a.name} download timed out');
      return null;
    } finally {
      _inFlight.remove(a.name);
      // Whatever happened, do not leave the job (or its partial file) behind.
      final done = await UpdateNative.pollDownload(id);
      if ('${done['status']}' != 'success') {
        await UpdateNative.removeDownload(id);
      }
    }
  }

  Future<void> _delete(String path) async {
    if (deleteOverride != null) return deleteOverride!(path);
    try {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  /// Keep the newest [keepPerChannel] versions; delete every file belonging to
  /// an older one. Deleting from the directory is the whole publish API — the
  /// folder differ emits the signed `rmFile` ops on its next sweep.
  Future<void> _prune(String dir, String folderId) async {
    final victims =
        mirrorPruneVictims(_heldNames(dir), keep: keepPerChannel);
    if (victims.isEmpty) return;
    for (final name in victims) {
      await _delete('$dir${Platform.pathSeparator}$name');
    }
    LogService.instance
        .add('update-mirror: pruned ${victims.length} file(s) from $dir');
    unawaited(RnsService.instance.folderRescan(folderId));
  }

  void _refreshHeld(String channel, String dir) {
    final names = _heldNames(dir);
    final versions = <String>{};
    var bytes = 0;
    for (final n in names) {
      final v = versionFromAssetName(n);
      if (v != null) versions.add(v);
      try {
        bytes += File('$dir${Platform.pathSeparator}$n').lengthSync();
      } catch (_) {}
    }
    final sorted = versions.toList()
      ..sort((a, b) => compareSemver(b, a));
    _held[channel] = {
      'folderId': channel == 'stable' ? stableFolderId : betaFolderId,
      'dir': dir,
      'versions': sorted,
      'files': names.length,
      'bytes': bytes,
    };
  }

  Map<String, dynamic> statusJson() => {
        'enabled': enabled,
        'running': isRunning,
        'paused': isPaused,
        'intervalMinutes': pollInterval.inMinutes,
        'keepPerChannel': keepPerChannel,
        'lastPollMs': lastPollMs,
        'lastAddMs': lastAddMs,
        'error': lastError,
        'channels': _held,
        'inFlight': _inFlight.entries
            .map((e) => {'name': e.key, 'percent': e.value})
            .toList(),
      };
}

/// The name an artifact is stored under in a mirror directory.
///
/// Retention groups files by the version parsed out of their name, so a name
/// that does not carry one breaks it. v1.1.1 shipped
/// `xprs-android-arm64-v8a.apk`, which parses as version "android-arm64-v8a" --
/// five artifacts looking like five different releases, and a retention limit
/// of five that therefore never prunes anything.
///
/// The feed knows the version even when the filename does not, so rebuild the
/// name around it: `xprs-<version>-<rest>`. A name that already carries the
/// right version is returned untouched.
String mirrorFileName(String assetName, String version) {
  if (versionFromAssetName(assetName) == version) return assetName;
  var rest = assetName;
  for (final prefix in const ['xprs-', 'aurora-']) {
    if (rest.startsWith(prefix)) {
      rest = rest.substring(prefix.length);
      break;
    }
  }
  return 'xprs-$version-$rest';
}

/// Given the artifact filenames a channel directory holds, the ones to delete
/// so that only the newest [keep] VERSIONS survive.
///
/// Pure, and filenames only: no bytes, no directory listing counted by
/// `.length`, no folder browse (docs/performance.md 8.7 / arch_guard
/// `no-page-fetch-to-count`). A name whose version cannot be parsed is NEVER a
/// victim — a mirror must not delete a file it does not understand.
List<String> mirrorPruneVictims(Iterable<String> heldNames,
    {int keep = UpdateMirrorService.keepPerChannel}) {
  final byVersion = <String, List<String>>{};
  for (final n in heldNames) {
    final v = versionFromAssetName(n);
    if (v == null || v.isEmpty) continue;
    (byVersion[v] ??= <String>[]).add(n);
  }
  if (byVersion.length <= keep) return const [];
  final versions = byVersion.keys.toList()
    ..sort((a, b) => compareSemver(b, a)); // newest first
  final victims = <String>[];
  for (var i = keep; i < versions.length; i++) {
    victims.addAll(byVersion[versions[i]]!);
  }
  return victims;
}
