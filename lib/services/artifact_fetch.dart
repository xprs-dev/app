// =============================================================================
// artifact_fetch.dart — fetch one release artifact by its sha256, over the
// same three lanes the updater uses, into a folder the caller names.
//
//   1. the mesh: a station in earshot that holds it (XPRS.md 25.2.2), bytes
//      on the BLE bulk lane, written straight to disk;
//   2. Reticulum: an always-on archiver that mirrors releases (a DHT provider
//      record keyed on the sha256), or this device's own mirror;
//   3. the web: the feed's URL, streamed to disk.
//
// Every lane verifies the sha256 the feed announced before it answers. The
// caller keeps its own state (the updater's status bar, the Share page's row);
// this file only moves and checks bytes. Used by UpdateService (its own
// binary) and ShareLibrary (the other systems' installers).
//
// Memory: the mesh and web lanes never hold the file. The Reticulum lane
// returns the artifact as one Uint8List (a known cost, update_service.dart
// _downloadOverReticulum), for the length of one user-started fetch.
// =============================================================================

import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import '../platform/fs.dart';

import '../util/nostr_crypto.dart';
import 'log_service.dart';
import 'mesh/mesh_service.dart';
import 'reticulum/rns_service.dart';
import 'update_mirror_service.dart';
import 'update_models.dart';
import 'update_native.dart';
import 'xprs/xprs_catchup.dart';
import 'xprs/xprs_files.dart';
import 'xprs/xprs_monitor.dart';
import 'xprs/xprs_publisher.dart';

/// Which lane carried an artifact, as the updater reports it
/// (GET /api/update/status `lastSource`).
enum ArtifactSource { xprs, mirror, reticulum, https }

class FetchedArtifact {
  final String path;
  final ArtifactSource source;
  const FetchedArtifact(this.path, this.source);
}

class ArtifactFetch {
  ArtifactFetch._();

  /// A station's `link:ble` beacon counts as evidence of a bulk lane for this
  /// long — three beacon periods, the same window the publisher ranks paths on.
  static const int meshEvidenceMs = 3 * 60 * 1000;

  /// How long a station in earshot gets to say 202 before we ask the next one.
  static const Duration meshAcceptWithin = Duration(seconds: 30);

  /// How long the DHT gets to name a provider before we go to the web.
  static const Duration providerProbeTimeout = Duration(seconds: 20);

  /// The floor of a Reticulum fetch's deadline.
  static const Duration reticulumFetchTimeout = Duration(minutes: 5);

  /// The fetch deadline, sized to the artifact. A flat five minutes was
  /// measured on the bench to expire seconds AFTER a 35 MB swarm fetch
  /// finished at ~120 kB/s; a 57 MB APK at that rate would have been cut off
  /// at 85%. The floor is the old value; above it, a modest 20 kB/s budget so
  /// a slow-but-moving transfer is never abandoned while the bar is climbing.
  /// A fetch that actually stalls is ended by the swarm's own per-piece
  /// timeouts, not by this.
  static Duration reticulumTimeoutFor(int sizeBytes) {
    final budget = Duration(seconds: sizeBytes ~/ (20 * 1024));
    return budget > reticulumFetchTimeout ? budget : reticulumFetchTimeout;
  }

  static Future<bool> _ble5Active() async {
    for (final b in XprsPublisher.instance.bearers) {
      if (b.name == 'ble5') {
        return XprsPublisher.instance.isBearerEnabled('ble5') && await b.active;
      }
    }
    return false;
  }

  /// Stations that could hand us a file over the mesh right now: our radio
  /// is on, and the station declared `link:ble` recently (10.6.1) — not merely
  /// a callsign we archived a packet from. Measured on the bench: a desktop
  /// with no Bluetooth asked a phone it heard over LAN, got 202 in 200 ms, and
  /// then sat on it for the transfer's whole timeout with no lane for the
  /// bytes.
  static Future<List<String>> meshStations() async {
    if (MeshService.instance.tableCallsign.isEmpty) return const [];
    if (!await _ble5Active()) return const [];
    final now = DateTime.now().millisecondsSinceEpoch;
    return [
      for (final c in XprsCatchup.instance.stationsInEarshot())
        if (XprsMonitor.instance.stations[c.toUpperCase()]
                ?.declaredBearersFresh(now, meshEvidenceMs)
                .contains('ble') ??
            false)
          c,
    ];
  }

  static String _ext(String name) {
    final dot = name.lastIndexOf('.');
    return dot >= 0 ? name.substring(dot + 1) : '';
  }

  /// Ask each station in earshot in turn. One 250-byte packet to learn that a
  /// station does not hold it (404), so asking is cheap. [onStation] names the
  /// station being asked, for a progress line.
  static Future<FetchedArtifact?> overMesh(ReleaseAsset asset,
      {required String destDir, void Function(String station)? onStation}) async {
    if (asset.sha256.isEmpty) return null;
    final stations = await meshStations();
    if (stations.isEmpty) return null;
    final self = NostrCrypto.bareCallsign(MeshService.instance.tableCallsign);
    for (final station in stations) {
      onStation?.call(station);
      try {
        final path = await XprsFileFetch.instance.fetch(
          archiver: station,
          shaHex: asset.sha256,
          selfCallsign: self,
          ext: _ext(asset.name),
          // Land it as a file where the caller wants it: an APK that became a
          // database blob would have to be written back out to be used.
          destDir: destDir,
          // Seconds to say 202, not the transfer's hour: a station that does
          // not hold it is asked and left behind, never waited on.
          acceptWithin: meshAcceptWithin,
          // The feed states the length exactly: the internet lane can then
          // take pieces from every station that holds it.
          exactSize: asset.size,
        );
        if (path == null) continue; // 404 / refused / timed out
        LogService.instance
            .add('artifact: ${asset.name} arrived from $station over the mesh');
        return FetchedArtifact(path, ArtifactSource.xprs);
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  /// By content address over Reticulum: this device's own mirror first, then
  /// any always-on archiver the DHT names. Null, quietly, when nobody holds
  /// it, so the caller can go to the web. [folder] is the signed channel
  /// folder the artifact belongs to; [phaseOf] gets readable progress words
  /// (the updater's translated phases), [onProgress] 0..1.
  static Future<FetchedArtifact?> overReticulum(
    ReleaseAsset asset, {
    required String folder,
    required String destDir,
    void Function(ReticulumPhase phase, int providers)? onPhase,
    void Function(double progress)? onProgress,
  }) async {
    final shaHex = asset.sha256.toLowerCase();
    if (shaHex.length != 64) return null;
    final dest = '$destDir$pathSeparator${asset.name}';
    // An always-on archiver already holds every release it mirrors, verified
    // at ingest. The DHT probe below asks for OTHER providers by design, so
    // without this a mirror that was the only holder concluded nobody had it
    // and went to the web for bytes sitting on its own disk.
    final mine = UpdateMirrorService.instance.pathForSha(shaHex);
    if (mine != null) {
      onPhase?.call(ReticulumPhase.mirror, 0);
      await fs.file(mine).copy(dest);
      return FetchedArtifact(dest, ArtifactSource.mirror);
    }
    // Is there anybody to fetch FROM? With no always-on archiver holding it,
    // the fetch's timeout was spent learning that nobody did. Ask the DHT the
    // cheap question first.
    onPhase?.call(ReticulumPhase.search, 0);
    final providers = await RnsService.instance
        .contentProviderCount(shaHex, timeout: providerProbeTimeout);
    if (providers == 0) {
      LogService.instance
          .add('artifact: no always-on archiver holds ${asset.name} — web');
      return null;
    }
    onPhase?.call(ReticulumPhase.fetch, providers);
    final shaB = _hexBytes(shaHex);
    // Lives only while a fetch somebody started is in flight, cancelled in
    // the finally below: it never exists with nobody waiting.
    final ticker = Timer.periodic(const Duration(milliseconds: 500), (_) { // arch-ignore: no-sub-minute-poll bounded to one user-initiated download, cancelled in finally
      if (shaB == null || onProgress == null) return;
      final pr = RnsService.instance.fileFetchProgress(shaB);
      if (pr != null && pr.total > 0) onProgress(pr.received / pr.total);
    });
    Uint8List? bytes;
    try {
      bytes = await RnsService.instance.folderFetchBytes(folder, shaHex,
          ext: _ext(asset.name),
          timeout: reticulumTimeoutFor(asset.size),
          size: asset.size);
    } finally {
      ticker.cancel();
    }
    if (bytes == null || bytes.isEmpty) return null;
    // Content-addressed already, but a mismatch would mean handing on bytes
    // nobody vouched for. Assert it.
    if (crypto.sha256.convert(bytes).toString() != shaHex) {
      throw const ArtifactFetchException('sha mismatch');
    }
    final path = await UpdateNative.writeBytes(asset.name, bytes, (r, t) {
      if (t > 0) onProgress?.call(r / t);
    }, dir: destDir);
    if (path == null) throw const ArtifactFetchException('write failed');
    LogService.instance.add(
        'artifact: ${asset.name} fetched over Reticulum (${bytes.length} B)');
    return FetchedArtifact(path, ArtifactSource.reticulum);
  }

  /// Stream the feed's URL to [destDir] and check size and sha256. Null when
  /// the download or the check fails (the partial file is removed).
  static Future<FetchedArtifact?> overWeb(ReleaseAsset asset,
      {required String destDir,
      void Function(int received, int total)? onProgress}) async {
    final lower = asset.url.toLowerCase();
    if (!lower.startsWith('http://') && !lower.startsWith('https://')) {
      return null;
    }
    final path = await UpdateNative.download(
        asset.url, asset.name, onProgress ?? (_, _) {},
        dir: destDir);
    if (path == null) return null;
    if (!await UpdateNative.verifyFile(path,
        expectedSize: asset.size, expectedSha: asset.sha256)) {
      try {
        await fs.file(path).delete();
      } catch (_) {}
      return null;
    }
    return FetchedArtifact(path, ArtifactSource.https);
  }

  static Uint8List? _hexBytes(String hex) {
    if (hex.length != 64) return null;
    try {
      return Uint8List.fromList([
        for (var i = 0; i < 64; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
    } catch (_) {
      return null;
    }
  }
}

/// What the Reticulum lane is doing, for the caller to put into words.
enum ReticulumPhase { mirror, search, fetch }

class ArtifactFetchException implements Exception {
  final String message;
  const ArtifactFetchException(this.message);
  @override
  String toString() => 'ArtifactFetchException($message)';
}
