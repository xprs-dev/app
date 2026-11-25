// =============================================================================
// share_library.dart — the installers this device hands on for OTHER systems.
//
// The app carries only its own binary (and only on Android can it hand that
// on). A person who wants to give a Windows, Linux or macOS user the app, or
// a desktop that wants to give a phone the APK, adds that system here: the
// newest build of their update channel is fetched once, by its sha256, over
// the updater's own lanes (ArtifactFetch: a station in earshot, an always-on
// archiver over Reticulum, then xprs.dev), and kept in `<support>/share/`.
// The web portal (ShareAppService) serves whatever is in that folder.
//
// Nothing is bundled and nothing is fetched until somebody taps Add: the
// binaries are 30-55 MB each.
// =============================================================================

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/fs.dart';
import 'package:xprs_core/src/platform/core_host.dart' show CoreHost;
import 'artifact_fetch.dart';
import 'log_service.dart';
import 'update_models.dart';
import 'update_native.dart';
import 'update_platform.dart';
import 'update_service.dart';

/// One file the portal can hand out.
class ShareEntry {
  final UpdatePlatform platform;
  final String name;
  final String path;
  final int size;

  /// This running app's own APK (Android), not a file in the library.
  final bool self;
  const ShareEntry(
      {required this.platform,
      required this.name,
      required this.path,
      required this.size,
      this.self = false});
}

/// The systems a person can add, in the order the page lists them.
const List<UpdatePlatform> kSharePlatforms = [
  UpdatePlatform.android,
  UpdatePlatform.windows,
  UpdatePlatform.linux,
  UpdatePlatform.macos,
];

/// Which system an artifact file is for, from its name, or null.
UpdatePlatform? sharePlatformOf(String name) {
  final n = name.toLowerCase();
  if (versionFromAssetName(n) == null) return null;
  if (n.endsWith('.apk')) return UpdatePlatform.android;
  if (n.endsWith('.exe')) return UpdatePlatform.windows;
  if (n.contains('linux') && n.endsWith('.tar.gz')) return UpdatePlatform.linux;
  if (n.contains('mac') && (n.endsWith('.zip') || n.endsWith('.dmg'))) {
    return UpdatePlatform.macos;
  }
  return null;
}

class ShareLibrary {
  ShareLibrary._();
  static final ShareLibrary instance = ShareLibrary._();

  /// The files in the library, one per system at most.
  final ValueNotifier<List<ShareEntry>> files = ValueNotifier(const []);

  /// Systems being fetched now: progress 0..1, or -1 while a lane has not
  /// said how far it is.
  final ValueNotifier<Map<UpdatePlatform, double>> busy = ValueNotifier(const {});

  /// The release the Add buttons fetch from, once known (sizes, macOS absent).
  final ValueNotifier<ReleaseInfo?> release = ValueNotifier(null);

  String? _dir;

  Future<String?> dir() async {
    if (_dir != null) return _dir;
    final updates = await UpdateNative.supportDir();
    if (updates == null) return null;
    final d = fs.directory('${fs.path.dirname(updates)}${pathSeparator}share');
    if (!await d.exists()) await d.create(recursive: true);
    return _dir = d.path;
  }

  /// Read the folder: names only, never bytes.
  Future<void> load() async {
    final d = await dir();
    if (d == null) return;
    final out = <ShareEntry>[];
    try {
      await for (final e in fs.directory(d).list()) {
        final name = fs.path.basename(e.path);
        final p = sharePlatformOf(name);
        if (p == null) continue;
        final st = await e.stat();
        out.add(ShareEntry(platform: p, name: name, path: e.path, size: st.size));
      }
    } catch (_) {}
    out.sort((a, b) => kSharePlatforms
        .indexOf(a.platform)
        .compareTo(kSharePlatforms.indexOf(b.platform)));
    files.value = out;
  }

  /// The newest release on this device's update channel: the feed when it
  /// answers (~1 KB), else what the updater last learned (kept across
  /// restarts), so a phone with no internet can still fetch from a station.
  Future<ReleaseInfo?> refreshRelease() async {
    final u = UpdateService.instance;
    final beta = u.betaEnabled;
    final r = await u.releaseFromFeed(beta ? 'beta.json' : 'stable.json',
            prereleaseOk: beta) ??
        (beta ? (u.beta.value ?? u.stable.value) : u.stable.value);
    if (r != null) release.value = r;
    return release.value;
  }

  /// The artifact [platform] would be fetched as, from [r].
  Future<ReleaseAsset?> assetFor(ReleaseInfo r, UpdatePlatform platform) async {
    // A phone receiving it is most likely arm64; this phone's own ABIs come
    // first when it is one.
    final abis = currentUpdatePlatform() == UpdatePlatform.android
        ? await UpdateNative.supportedAbis()
        : const <String>[];
    return r.assetFor(platform, androidAbis: [...abis, 'arm64-v8a']);
  }

  void _progress(UpdatePlatform p, double v) =>
      busy.value = {...busy.value, p: v};

  /// Fetch [platform]'s installer into the library. Returns null on success,
  /// or why not: `release` (no release known), `missing` (the release has no
  /// build for it), `failed` (no lane delivered it).
  Future<String?> add(UpdatePlatform platform) async {
    if (busy.value.containsKey(platform)) return null;
    _progress(platform, -1);
    // A 50 MB fetch outlives the screen going off (performance.md 8.2).
    unawaited(CoreHost.keepAlive.hold(_holder(platform)));
    try {
      final r = await refreshRelease();
      if (r == null) return 'release';
      final asset = await assetFor(r, platform);
      if (asset == null) return 'missing';
      final d = await dir();
      if (d == null) return 'failed';
      final incoming = '$d$pathSeparator.incoming';
      final inDir = fs.directory(incoming);
      if (!await inDir.exists()) await inDir.create(recursive: true);

      FetchedArtifact? got;
      try {
        got = await ArtifactFetch.overMesh(asset, destDir: incoming);
      } catch (_) {}
      if (got == null && asset.sha256.isNotEmpty) {
        try {
          final u = UpdateService.instance;
          got = await ArtifactFetch.overReticulum(asset,
              folder: r.isPrerelease ? u.betaFolder : u.stableFolder,
              destDir: incoming,
              onProgress: (v) => _progress(platform, v));
        } catch (_) {}
      }
      got ??= await ArtifactFetch.overWeb(asset,
          destDir: incoming,
          onProgress: (rx, total) {
            final t = total > 0 ? total : asset.size;
            if (t > 0) _progress(platform, (rx / t).clamp(0.0, 1.0));
          });
      if (got == null) return 'failed';

      // One file per system: the older build leaves when the new one lands.
      for (final old in files.value.where((e) => e.platform == platform)) {
        try {
          await fs.file(old.path).delete();
        } catch (_) {}
      }
      await fs.file(got.path).rename('$d$pathSeparator${asset.name}');
      LogService.instance.add(
          'share: added ${asset.name} (${got.source.name}, ${asset.size} B)');
      await load();
      return null;
    } catch (e) {
      LogService.instance.add('share: adding ${platform.name} failed: $e');
      return 'failed';
    } finally {
      busy.value = {...busy.value}..remove(platform);
      unawaited(CoreHost.keepAlive.release(_holder(platform)));
    }
  }

  Future<void> remove(UpdatePlatform platform) async {
    for (final e in files.value.where((e) => e.platform == platform)) {
      try {
        await fs.file(e.path).delete();
      } catch (_) {}
    }
    await load();
  }

  static String _holder(UpdatePlatform p) => 'share-add-${p.name}';
}
