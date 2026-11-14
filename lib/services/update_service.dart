/*
 * UpdateService — in-app updater for XPRS.
 *
 * Decentralized, authenticated updates over Reticulum. The publisher owns two
 * signed mutable folders (an IPNS-like, secp256k1-signed content-addressed
 * store) — one per channel:
 *   stable -> the stable folder npub  (only non-prerelease releases)
 *   beta   -> the beta folder npub    (all releases)
 * Each release's per-platform binaries are packed into the folder as
 * content-addressed entries named `xprs-<version>-<platform>` (see
 * update_models.versionFromAssetName). The app browses the channel folder
 * (signature-verified by reduceFolder, so only the folder owner can publish a
 * binary), compares the running version (lib/version.dart kAppVersion) with
 * semver (pre-release aware), fetches the artifact bytes peer-to-peer by sha256,
 * verifies sha256(bytes) == the entry hash, and applies it natively (see
 * update_native_io.dart). No central web host; any device that holds a binary
 * re-seeds it. Web is a no-op. Both folder npubs are overridable at runtime
 * (Updates panel) for self-hosters.
 */

import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../version.dart';
import 'reticulum/rns_service.dart';
import 'update_models.dart';
import 'update_platform.dart';
import 'update_native.dart';
import '../util/nostr_crypto.dart';
import 'log_service.dart';
import 'i18n/core_i18n.dart';
import 'mesh/mesh_service.dart';
import 'update_mirror_service.dart';
import 'xprs/xprs_catchup.dart';
import 'xprs/xprs_publisher.dart';
import 'xprs/xprs_monitor.dart';
import 'xprs/xprs_files.dart';
import 'notification_service.dart';
import '../platform/fs.dart';

enum UpdateStatus { idle, checking, available, downloading, downloaded, error }

class UpdateService with WidgetsBindingObserver {
  UpdateService._() {
    for (final n in <Listenable>[status, stable, beta, fdroid]) {
      n.addListener(_refreshNotice);
    }
  }
  static final UpdateService instance = UpdateService._();

  // Release source — two signed Reticulum mutable folders (the publisher holds
  // the master private key of each; consumers verify the op signatures and the
  // sha256 of every binary). The stable folder carries only non-prerelease
  // builds; the beta folder carries all builds. Pinned here as the folder
  // addresses (npub or hex folderId); overridable at runtime in the Update
  // Center so self-hosters can point at their own folders. Empty by default
  // until the publisher's folders are created and their npubs baked in — an
  // empty pin simply yields "no release on that channel", never an error.
  static const String defaultUpdateFolderStableNpub = '';
  static const String defaultUpdateFolderBetaNpub = '';

  String _stableFolder = defaultUpdateFolderStableNpub;
  String _betaFolder = defaultUpdateFolderBetaNpub;
  String get stableFolder => _stableFolder;
  String get betaFolder => _betaFolder;

  // The feed announces; it does not host. Each channel is a small JSON document
  // naming the newest version and, for every artifact, its size, its absolute
  // download URL and its sha256. The sha256 is the address: the bytes normally
  // arrive over Reticulum from an always-on archiver that has already mirrored them,
  // so an ordinary phone never makes an HTTPS request for a binary at all. The
  // URL is the fallback for a device with no Reticulum path to any mirror.
  // Overridable at runtime for self-hosters.
  static const String defaultUpdateFeedBase = 'https://xprs.dev/updates';
  String _feedBase = defaultUpdateFeedBase;
  String get feedBase => _feedBase;

  /// Device ABIs in preference order (Android), cached; drives per-ABI split-APK
  /// selection. Empty on non-Android.
  List<String>? _androidAbis;
  Future<List<String>> _abis() async =>
      _androidAbis ??= await UpdateNative.supportedAbis();

  // Persisted settings keys (SharedPreferences, "flutter." prefixed on disk).
  static const _kBeta = 'update.betaEnabled';
  // Absent until the user flips the switch: the default follows the installer
  // (defaultAutoUpdate).
  static const _kAuto = 'update.auto';
  static const _kOverMetered = 'update.overMetered';
  static const _kLastCheck = 'update.lastCheck';
  static const _kNotified = 'update.lastNotifiedVersion';
  // The verified download waiting to be installed, so a restart neither
  // downloads it again nor hashes it again.
  static const _kReadyPath = 'update.ready.path';
  static const _kReadyVersion = 'update.ready.version';
  static const _kReadySize = 'update.ready.size';
  static const _kStableFolder = 'update.folder.stable';
  static const _kBetaFolder = 'update.folder.beta';
  static const _kFeedBase = 'update.feed.base';
  // Absent until the user flips the switch: the default follows the installer.
  static const _kFdroidOnly = 'update.fdroidOnly';
  // Active DownloadManager job (Android), persisted so an interrupted or
  // backgrounded download can be re-attached when the Updates panel reopens or
  // the app is relaunched.
  static const _kDlId = 'update.dl.id';
  static const _kDlVersion = 'update.dl.version';
  static const _kDlName = 'update.dl.name';
  static const _kDlSize = 'update.dl.size';
  static const _kDlSha = 'update.dl.sha';
  static const _kDlPre = 'update.dl.prerelease';

  final ValueNotifier<UpdateStatus> status =
      ValueNotifier(UpdateStatus.idle);
  final ValueNotifier<double> progress = ValueNotifier(0); // 0..1
  final ValueNotifier<ReleaseInfo?> stable = ValueNotifier(null);
  final ValueNotifier<ReleaseInfo?> beta = ValueNotifier(null);
  /// The newest version F-Droid publishes, when [fdroidOnly] is on.
  final ValueNotifier<ReleaseInfo?> fdroid = ValueNotifier(null);
  /// The last thing that went wrong, for the Updates page; null when nothing
  /// did. A notifier so the page shows it without the status changing.
  final ValueNotifier<String?> errorNote = ValueNotifier(null);
  String? get error => errorNote.value;
  set error(String? v) => errorNote.value = v;
  String? _downloadedPath;

  /// Which path carried the last download: 'reticulum', 'https', or null when
  /// nothing has been downloaded. Reported by GET /api/update/status so a test
  /// can assert the bytes did NOT come off the web.
  String? lastSource;

  /// What the download is doing RIGHT NOW, in words a person can read on the
  /// progress bar: which station is being asked, which lane is carrying it.
  /// A bar sitting at 0% with no words was indistinguishable from a download
  /// that had not started -- which is exactly how the fault above was
  /// reported.
  final ValueNotifier<String> phase = ValueNotifier('');

  static Uint8List? _hexBytes(String hex) {
    if (hex.length != 64) return null;
    try {
      return Uint8List.fromList([
        for (var i = 0; i < 64; i += 2) int.parse(hex.substring(i, i + 2), radix: 16),
      ]);
    } catch (_) {
      return null;
    }
  }

  /// A station's `link:ble` beacon counts as evidence of a bulk lane for this
  /// long — three beacon periods, the same window the publisher ranks paths on.
  static const int meshEvidenceMs = 3 * 60 * 1000;

  Future<bool> _ble5Active() async {
    for (final b in XprsPublisher.instance.bearers) {
      if (b.name == 'ble5') {
        return XprsPublisher.instance.isBearerEnabled('ble5') && await b.active;
      }
    }
    return false;
  }

  /// How long a station in earshot gets to say 202 before we ask the next one.
  static const Duration meshAcceptWithin = Duration(seconds: 30);

  /// How long the DHT gets to name a provider before we go to the web.
  static const Duration providerProbeTimeout = Duration(seconds: 20);

  /// How long to wait for a Reticulum provider before falling back to the web.
  /// Long enough for a DHT resolve plus a multi-source transfer of a ~60 MB
  /// artifact, short enough that a phone with no mirror in reach is not stuck.
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

  // True while a DownloadManager poll loop is running, so we never spin up a
  // second tracker (e.g. resume racing a fresh download).
  bool _tracking = false;

  bool _betaEnabled = false;
  bool? _autoChoice; // null until the user chooses
  bool _autoDefault = true;
  bool _overMetered = false;
  bool _fdroidOnly = false;
  int? _lastCheckMs;
  String? _readyVersion;
  bool get betaEnabled => _betaEnabled;

  /// Automatic updates: check every [checkInterval] while the app runs,
  /// download a newer release in the background, and say once that it is
  /// ready to install. Never while F-Droid is the updater.
  bool get autoUpdate =>
      supported && !fdroidOnly && (_autoChoice ?? _autoDefault);

  /// The old name, still read by the remote API.
  bool get autoCheck => autoUpdate;

  /// Whether an automatic download may use mobile data. Off by default: the
  /// system DownloadManager then waits for Wi-Fi by itself. A download the
  /// user starts from the Updates page always may.
  bool get overMetered => _overMetered;

  DateTime? get lastCheck => _lastCheckMs == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(_lastCheckMs!);

  /// When the next automatic check is armed for, or null when none is.
  DateTime? get nextCheck => _nextAt;
  DateTime? _nextAt;

  /// The version of the verified download waiting to be installed.
  String? get readyVersion => _readyVersion;

  /// What the launcher shows (a dot on the menu and the drawer entry, a
  /// banner when an update is ready to install).
  final ValueNotifier<UpdateNotice> notice = ValueNotifier(UpdateNotice.none);

  /// A check is running. Separate from [status] so that checking while a
  /// download runs (or waits to be installed) does not hide either.
  final ValueNotifier<bool> checking = ValueNotifier(false);

  /// Set while the Updates page is on screen: no "ready" notification then.
  bool pageOpen = false;

  /// How often the running app looks for a newer release. Releases ship at
  /// most weekly; the feed is ~1 KB.
  static const Duration checkInterval = Duration(hours: 6);

  /// A failed check (no network) is retried sooner than [checkInterval].
  static const Duration retryAfterFailure = Duration(minutes: 30);

  /// The first check after start-up waits this long, so it never competes
  /// with the app coming up.
  static const Duration startDelay = Duration(minutes: 1);

  Timer? _timer;
  bool _started = false;

  /// Compile-time default for automatic updates when Android names no
  /// installer (an `adb install`). Every Android release is built with
  ///
  ///     flutter build apk --dart-define=AUTO_UPDATE_CHECK=false
  ///
  /// because F-Droid asked for it (fdroiddata !48456) and F-Droid ships the
  /// very APK the release pipeline builds from fdroid/com.xprs.app.yml. It
  /// used to switch the start-up check off for every install of that APK, so
  /// a phone that installed it from xprs.dev never looked for an update. It
  /// now decides only the installer-less case; see [defaultAutoUpdate] and
  /// docs/updates.md section 6.
  static const bool autoCheckEnabled =
      bool.fromEnvironment('AUTO_UPDATE_CHECK', defaultValue: true);

  /// "Updates only from F-Droid" (Android). XPRS then never downloads itself:
  /// it asks F-Droid which version it publishes, and hands an update to the
  /// F-Droid client. On by default when an F-Droid client installed this copy.
  ///
  /// F-Droid ships the very APK released here (a reproducible build, signed
  /// with the same key), so either updater can install over the other. The
  /// switch only decides which one this phone listens to.
  bool get fdroidOnly => _fdroidOnly && fdroidAvailable;
  bool get fdroidAvailable => currentUpdatePlatform() == UpdatePlatform.android;

  /// Package names of the F-Droid clients (keep in step with the manifest's
  /// `queries` and UpdateBridge.FDROID_CLIENTS).
  static const fdroidClients = fdroidClientPackages;

  /// F-Droid's public index entry for XPRS: the versions it publishes.
  static const String fdroidApi =
      'https://f-droid.org/api/v1/packages/com.xprs.app';

  String get currentVersion => kAppVersion;
  /// Compile-time kill switch for the whole self-update path, for anyone who
  /// repackages XPRS behind an updater of their own:
  ///
  ///     flutter build apk --dart-define=SELF_UPDATE=false
  ///
  /// makes this report unsupported, so every check, download and install path
  /// short-circuits and the Updates panel hides itself. Official builds keep it
  /// on, F-Droid's included (it rebuilds the release byte for byte); an
  /// F-Droid install defaults to [fdroidOnly] instead.
  static const bool selfUpdateEnabled =
      bool.fromEnvironment('SELF_UPDATE', defaultValue: true);

  bool get supported => selfUpdateEnabled && UpdateNative.supported;
  String? get downloadedPath => _downloadedPath;

  Future<void> _prefs(void Function(SharedPreferences p) fn) async {
    final p = await SharedPreferences.getInstance();
    fn(p);
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _betaEnabled = p.getBool(_kBeta) ?? false;
    _autoChoice = p.getBool(_kAuto);
    _overMetered = p.getBool(_kOverMetered) ?? false;
    _lastCheckMs = p.getInt(_kLastCheck);
    final s = p.getString(_kStableFolder);
    final b = p.getString(_kBetaFolder);
    _stableFolder =
        (s != null && s.isNotEmpty) ? s : defaultUpdateFolderStableNpub;
    _betaFolder = (b != null && b.isNotEmpty) ? b : defaultUpdateFolderBetaNpub;
    final f = p.getString(_kFeedBase);
    _feedBase = (f != null && f.isNotEmpty) ? f : defaultUpdateFeedBase;
    // Not stored until the user chooses, so the default keeps following the
    // installer: F-Droid installed it, F-Droid updates it.
    final installer = fdroidAvailable ? await _installer() : null;
    _fdroidOnly = p.getBool(_kFdroidOnly) ??
        (fdroidAvailable && fdroidClients.contains(installer));
    _autoDefault = defaultAutoUpdate(
        android: fdroidAvailable,
        installer: installer,
        storeDefine: autoCheckEnabled);
    _refreshNotice();
  }

  // Asked once per process: only an install replaces the installer, and an
  // install restarts the process.
  Future<String?>? _installerF;
  Future<String?> _installer() =>
      _installerF ??= UpdateNative.installerPackage();

  Future<void> setFdroidOnly(bool v) async {
    _fdroidOnly = v;
    await _prefs((p) => p.setBool(_kFdroidOnly, v));
    _arm();
    _refreshNotice();
  }

  /// Hand the update to the F-Droid client (or f-droid.org when none is
  /// installed). Returns false when nothing could be opened.
  Future<bool> openFdroid() async => await UpdateNative.openFdroid() != null;

  /// Change the website feed base URL (e.g. https://xprs.dev/updates). Pass
  /// empty to reset to the default. Returns the normalised value stored.
  Future<String> setFeedBase(String input) async {
    final v = input.trim();
    _feedBase = v.isEmpty ? defaultUpdateFeedBase : v;
    await _prefs((p) => p.setString(_kFeedBase, _feedBase));
    return _feedBase;
  }

  Future<void> setBetaEnabled(bool v) async {
    _betaEnabled = v;
    await _prefs((p) => p.setBool(_kBeta, v));
  }

  /// Change the stable-channel folder address (npub or hex folderId). Pass
  /// empty to reset to the default pin. Returns the normalised value stored.
  Future<String> setStableFolder(String input) async {
    final v = input.trim();
    _stableFolder = v.isEmpty ? defaultUpdateFolderStableNpub : v;
    await _prefs((p) => p.setString(_kStableFolder, _stableFolder));
    return _stableFolder;
  }

  /// Change the beta-channel folder address (npub or hex folderId). Pass empty
  /// to reset to the default pin. Returns the normalised value stored.
  Future<String> setBetaFolder(String input) async {
    final v = input.trim();
    _betaFolder = v.isEmpty ? defaultUpdateFolderBetaNpub : v;
    await _prefs((p) => p.setString(_kBetaFolder, _betaFolder));
    return _betaFolder;
  }

  Future<void> setAutoUpdate(bool v) async {
    _autoChoice = v;
    await _prefs((p) => p.setBool(_kAuto, v));
    _arm();
  }

  Future<void> setOverMetered(bool v) async {
    _overMetered = v;
    await _prefs((p) => p.setBool(_kOverMetered, v));
  }

  /// The release the user should be offered: F-Droid's when [fdroidOnly],
  /// otherwise the channel the beta toggle picks.
  ReleaseInfo? get selectedRelease => fdroidOnly
      ? fdroid.value
      : (_betaEnabled ? beta.value : stable.value);

  /// True if [r] is newer than what's running.
  bool isNewer(ReleaseInfo? r) =>
      r != null && compareSemver(r.version, kAppVersion) > 0;

  /// Read the feed (website first, the signed Reticulum folder as fallback)
  /// and pick the newest release on each channel; with [fdroidOnly], ask
  /// F-Droid's index instead. Returns whether any source answered, so the
  /// scheduler knows to retry sooner. A running download, or one waiting to
  /// be installed, keeps its status.
  Future<bool> checkForUpdates() async {
    if (!supported) return false;
    if (checking.value) return false;
    checking.value = true;
    if (_statusIsQuiet) status.value = UpdateStatus.checking;
    error = null;
    var answered = false;
    try {
      if (fdroidOnly) {
        fdroid.value = await _newestFromFdroid();
        answered = fdroid.value != null;
      } else {
        stable.value =
            await _newestFromFeed('stable.json', prereleaseOk: false) ??
                await _newestFromFolder(_stableFolder, prereleaseOk: false);
        // The beta channel falls back to the newest stable when there's no
        // beta build on either source.
        final b = await _newestFromFeed('beta.json', prereleaseOk: true) ??
            await _newestFromFolder(_betaFolder, prereleaseOk: true);
        beta.value = b ?? stable.value;
        answered = stable.value != null || b != null;
      }
      if (answered) {
        _lastCheckMs = DateTime.now().millisecondsSinceEpoch;
        await _prefs((p) => p.setInt(_kLastCheck, _lastCheckMs!));
      }
      _settleStatus();
    } catch (e) {
      error = e.toString();
      if (_statusIsQuiet) status.value = UpdateStatus.error;
    } finally {
      checking.value = false;
    }
    return answered;
  }

  /// Not downloading and nothing waiting to be installed.
  bool get _statusIsQuiet =>
      status.value != UpdateStatus.downloading &&
      status.value != UpdateStatus.downloaded;

  /// Status after a check: a running download stays; a verified download
  /// that is still worth installing reads "downloaded"; otherwise available
  /// or idle.
  void _settleStatus() {
    if (status.value == UpdateStatus.downloading) return;
    if (_hasReady) {
      status.value = UpdateStatus.downloaded;
    } else {
      status.value =
          isNewer(selectedRelease) ? UpdateStatus.available : UpdateStatus.idle;
    }
  }

  bool get _hasReady =>
      _downloadedPath != null &&
      _readyVersion != null &&
      compareSemver(_readyVersion!, kAppVersion) > 0;

  void _refreshNotice() {
    notice.value = updateNoticeFor(
      newerKnown: isNewer(selectedRelease),
      downloading: status.value == UpdateStatus.downloading,
      ready: _hasReady && !fdroidOnly,
    );
  }

  /// One channel of the feed, for a caller that wants the document rather than
  /// the "is there an update for me" answer — the update mirror, which is
  /// interested in every artifact regardless of this device's platform.
  Future<ReleaseInfo?> releaseFromFeed(String channelFile,
          {required bool prereleaseOk}) =>
      _newestFromFeed(channelFile, prereleaseOk: prereleaseOk);

  /// Fetch one channel from the xprs.dev feed over HTTP and parse it. The
  /// feed's relative asset URLs are resolved against the feed base. Returns null
  /// on any error / non-200 / empty so the caller falls back to Reticulum. With
  /// [prereleaseOk] false, a prerelease document is ignored.
  Future<ReleaseInfo?> _newestFromFeed(String channelFile,
      {required bool prereleaseOk}) async {
    final raw = _feedBase.trim();
    if (raw.isEmpty) return null;
    final base = raw.endsWith('/') ? raw.substring(0, raw.length - 1) : raw;
    try {
      final resp = await http
          .get(Uri.parse('$base/$channelFile'))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(utf8.decode(resp.bodyBytes));
      if (json is! Map<String, dynamic>) return null;
      final r = ReleaseInfo.fromFeed(json, baseUrl: base);
      if (r.version.isEmpty) return null;
      if (!prereleaseOk && r.isPrerelease) return null;
      return r;
    } catch (_) {
      return null; // unreachable / malformed → fall back to Reticulum
    }
  }

  /// The newest version F-Droid publishes, from its public index API, or null
  /// when F-Droid is unreachable or does not carry XPRS yet. Each version is
  /// there once per ABI; only the version name matters here. No assets: the
  /// F-Droid client does the downloading.
  Future<ReleaseInfo?> _newestFromFdroid() async {
    try {
      final resp = await http
          .get(Uri.parse(fdroidApi))
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(utf8.decode(resp.bodyBytes));
      if (json is! Map<String, dynamic>) return null;
      String? best;
      for (final p in (json['packages'] as List? ?? const [])) {
        final v = p is Map ? p['versionName'] : null;
        if (v is! String || v.isEmpty) continue;
        if (best == null || compareSemver(v, best) > 0) best = v;
      }
      if (best == null) return null;
      return ReleaseInfo(
          version: best, tagName: 'v$best', name: 'XPRS $best', assets: const []);
    } catch (_) {
      return null;
    }
  }

  /// Browse one channel folder and return its newest release (or null). With
  /// [prereleaseOk] false, prerelease versions are ignored so the stable
  /// channel never offers a beta even if the folder happens to hold one.
  Future<ReleaseInfo?> _newestFromFolder(String folder,
      {required bool prereleaseOk}) async {
    if (folder.isEmpty) return null;
    final state = await RnsService.instance.folderBrowseAsync(folder);
    ReleaseInfo? best;
    for (final r in releasesFromFolder(state)) {
      if (!prereleaseOk && r.isPrerelease) continue;
      if (best == null || compareSemver(r.version, best.version) > 0) {
        best = r;
      }
    }
    return best;
  }

  // ── Automatic updates ─────────────────────────────────────────────────

  /// Start the updater: restore a download waiting to be installed, re-attach
  /// to one still running, and arm the periodic check. Called once at boot;
  /// safe to call again.
  Future<void> start() async {
    if (!supported || _started) return;
    _started = true;
    await load();
    await _restoreReady();
    await resumeActiveDownload();
    try {
      WidgetsBinding.instance.addObserver(this);
    } catch (_) {}
    _arm();
  }

  /// Arm the next automatic check: at [checkInterval] after the last one, no
  /// sooner than [minDelay]. One one-shot timer, re-armed after every check;
  /// nothing runs while automatic updates are off.
  void _arm({Duration minDelay = startDelay, Duration? after}) {
    _timer?.cancel();
    _timer = null;
    _nextAt = null;
    if (!_started || !autoUpdate) return;
    final d = after ??
        updateNextCheckIn(
            lastCheckMs: _lastCheckMs,
            nowMs: DateTime.now().millisecondsSinceEpoch,
            interval: checkInterval,
            minDelay: minDelay);
    _nextAt = DateTime.now().add(d);
    _timer = Timer(d, () => unawaited(runAutomatic()));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !autoUpdate) return;
    // Back from the background after a long sleep (the timer may not have
    // fired while the process was frozen): check soon, if a check is due.
    if (updateCheckDue(
        lastCheckMs: _lastCheckMs,
        nowMs: DateTime.now().millisecondsSinceEpoch,
        interval: checkInterval)) {
      _arm(minDelay: const Duration(seconds: 5));
    }
  }

  /// One automatic round: check, and when a newer release is out, download
  /// it in the background and say once that it is ready. Also what
  /// POST /api/update/auto runs.
  Future<void> runAutomatic() async {
    if (!autoUpdate) return;
    final answered = await checkForUpdates();
    // Re-arm before the download: a download waiting for Wi-Fi can take hours.
    _arm(after: answered ? checkInterval : retryAfterFailure);
    final sel = selectedRelease;
    if (sel == null || !isNewer(sel)) return;
    if (readyCovers(
        readyVersion: _readyVersion, wanted: sel.version, running: kAppVersion)) {
      _notifyReady(sel.version);
      return;
    }
    if (status.value == UpdateStatus.downloading || _tracking) return;
    LogService.instance.add('update: ${sel.version} found, downloading');
    await download(sel, auto: true);
  }

  /// Post "XPRS `version` is ready to install" once per version. Its tap opens
  /// the Updates page (the `host:updates` notification target).
  Future<void> _notifyReady(String version) async {
    if (pageOpen) return;
    final p = await SharedPreferences.getInstance();
    if (p.getString(_kNotified) == version) return;
    await p.setString(_kNotified, version);
    NotificationService.instance.show(XprsNotification(
      level: NotificationLevel.info,
      title: tr('notifications.update.ready', {'version': version}),
      body: tr('notifications.update.ready.body'),
      source: notificationSource,
      scope: NotificationScope.both,
    ));
  }

  /// The notification source whose tap opens the Updates page.
  static const String notificationSource = 'host:updates';

  /// A verified artifact is on disk: remember it, so a restart neither
  /// downloads nor hashes it again, and tell the user.
  Future<void> _markReady(String path, String version) async {
    final old = _downloadedPath;
    _downloadedPath = path;
    _readyVersion = version;
    progress.value = 1;
    status.value = UpdateStatus.downloaded;
    var size = 0;
    try {
      size = await fs.file(path).length();
    } catch (_) {}
    final p = await SharedPreferences.getInstance();
    await p.setString(_kReadyPath, path);
    await p.setString(_kReadyVersion, version);
    await p.setInt(_kReadySize, size);
    if (old != null && old != path) unawaited(_deleteQuietly(old));
    _refreshNotice();
    unawaited(_notifyReady(version));
  }

  /// Bring back the download that was waiting to be installed. Deletes it
  /// once it is installed (or older than what runs), and forgets it when the
  /// file is gone or no longer the size it was verified at.
  Future<void> _restoreReady() async {
    final p = await SharedPreferences.getInstance();
    final path = p.getString(_kReadyPath);
    final version = p.getString(_kReadyVersion);
    if (path == null || version == null) return;
    var keep = false;
    try {
      final f = fs.file(path);
      if (await f.exists()) {
        if (readyIsStale(readyVersion: version, running: kAppVersion)) {
          await _deleteQuietly(path);
        } else {
          keep = await f.length() == (p.getInt(_kReadySize) ?? -1);
        }
      }
    } catch (_) {}
    if (!keep) {
      for (final k in [_kReadyPath, _kReadyVersion, _kReadySize]) {
        await p.remove(k);
      }
      return;
    }
    _downloadedPath = path;
    _readyVersion = version;
    progress.value = 1;
    status.value = UpdateStatus.downloaded;
    _refreshNotice();
  }

  Future<void> _deleteQuietly(String path) async {
    try {
      final f = fs.file(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Download the artifact for [release] on the current platform. A website
  /// (http/https) asset is streamed over HTTPS from xprs.dev; a Reticulum
  /// asset (sha256 handle) is fetched peer-to-peer and sha-verified. The right
  /// per-ABI split APK is chosen on Android.
  ///
  /// [auto] is a download nobody asked for in person: it may not use mobile
  /// data unless [overMetered] says so (the Reticulum lane is skipped and the
  /// DownloadManager waits for Wi-Fi). A release already downloaded and
  /// verified is not downloaded again, and a DownloadManager job for it that
  /// was interrupted is resumed rather than restarted.
  Future<bool> download(ReleaseInfo release, {bool auto = false}) async {
    if (!supported) return false;
    if (fdroidOnly) {
      error = 'Updates come from F-Droid on this device';
      status.value = UpdateStatus.error;
      return false;
    }
    if (_downloadedPath != null &&
        readyCovers(
            readyVersion: _readyVersion,
            wanted: release.version,
            running: kAppVersion) &&
        await fs.file(_downloadedPath!).exists()) {
      progress.value = 1;
      status.value = UpdateStatus.downloaded;
      return true;
    }
    final allowData = !auto || _overMetered;
    final metered = allowData ? false : await UpdateNative.isMetered();
    final platform = currentUpdatePlatform();
    final abis =
        platform == UpdatePlatform.android ? await _abis() : const <String>[];
    final asset = release.assetFor(platform, androidAbis: abis);
    if (asset == null || asset.url.isEmpty) {
      error = 'No download for this platform in ${release.version}';
      status.value = UpdateStatus.error;
      return false;
    }

    // The mesh first, when a station is in earshot.
    //
    // XPRS.md section 25.2.2: `cmd:file` on the advert channel, the bytes on
    // the bulk lane, `code:200` once the receiver has hashed what it holds.
    // This is the lane that works with no internet at all — the phone asking
    // may have nothing but Bluetooth.
    if (asset.sha256.isNotEmpty) {
      final path = await _downloadOverMesh(release, asset);
      if (path != null) return true;
    }

    // Reticulum second, whenever the feed told us the artifact's sha256.
    //
    // The sha IS the address: an always-on archiver that mirrored this release
    // published a DHT provider record keyed on exactly this value, so the bytes
    // come peer-to-peer and this device never makes an HTTPS request for a
    // 60 MB binary. The URL below is the fallback for a device that cannot
    // reach any mirror.
    if (asset.sha256.isNotEmpty && !metered) {
      if (await _downloadOverReticulum(release, asset)) return true;
      // No provider yet, or the fetch timed out. Not an error — fall through to
      // the web and say afterwards which path actually carried it.
    }

    final lower0 = asset.url.toLowerCase();
    final isHttp0 =
        lower0.startsWith('http://') || lower0.startsWith('https://');
    // Android HTTP feed → the system DownloadManager: it keeps running after the
    // panel/app closes, resumes an interrupted transfer, and reports success
    // only once the whole file is on disk. The Dart isolate just mirrors its
    // progress. The Reticulum (sha handle) and desktop paths stay below.
    if (isHttp0) {
      lastSource = 'https';
      phase.value = 'Downloading from xprs.dev';
    }
    if (isHttp0 && UpdateNative.hasDownloadManager) {
      return _downloadViaManager(release, asset, overMetered: allowData);
    }

    status.value = UpdateStatus.downloading;
    progress.value = 0;
    error = null;
    UpdateNative.serviceStart('Downloading XPRS ${release.version}');
    try {
      void onProgress(int received, int total) {
        if (total > 0) {
          final v = received / total;
          progress.value = v;
          UpdateNative.serviceProgress(
              (v * 100).round(), 'Downloading ${release.version}');
        }
      }

      final lower = asset.url.toLowerCase();
      final isHttp =
          lower.startsWith('http://') || lower.startsWith('https://');
      String? path;
      if (isHttp) {
        // Website source (xprs.dev): stream the binary over HTTPS. Trust is
        // the TLS connection to the authoritative site; a size mismatch (when the
        // feed advertised one) is treated as a failed/partial download.
        path = await UpdateNative.download(asset.url, asset.name, onProgress);
        if (path == null) {
          error = 'Could not download the update from the website';
          status.value = UpdateStatus.error;
          return false;
        }
        if (!await UpdateNative.verifyFile(path,
            expectedSize: asset.size, expectedSha: asset.sha256)) {
          await _deleteQuietly(path);
          error = 'Update failed its integrity check';
          status.value = UpdateStatus.error;
          return false;
        }
      } else {
        // Reticulum source: asset.url holds the sha256 hex (content-addressed
        // fetch handle). The matching channel folder is where we look it up.
        final folder = release.isPrerelease ? _betaFolder : _stableFolder;
        final shaHex = lower;
        // Pass the artifact's extension (e.g. "apk") so the content-addressed
        // fetch can archive + re-seed it.
        final dot = asset.name.lastIndexOf('.');
        final ext = dot >= 0 ? asset.name.substring(dot + 1) : '';
        final bytes = await RnsService.instance.folderFetchBytes(folder, shaHex,
            ext: ext, timeout: const Duration(minutes: 5));
        if (bytes == null) {
          error = 'Could not fetch the update over Reticulum (no provider yet)';
          status.value = UpdateStatus.error;
          return false;
        }
        // Integrity: the entry hash is content-addressed; assert it anyway.
        final got = crypto.sha256.convert(bytes).toString();
        if (got != shaHex) {
          error = 'Update failed integrity check (sha mismatch)';
          status.value = UpdateStatus.error;
          return false;
        }
        path = await UpdateNative.writeBytes(asset.name, bytes, onProgress);
        if (path == null) {
          error = 'Could not write the update to disk';
          status.value = UpdateStatus.error;
          return false;
        }
      }
      await _markReady(path, release.version);
      return true;
    } finally {
      UpdateNative.serviceStop();
    }
  }

  /// Ask a station in earshot for the artifact, over XPRS + the bulk lane.
  ///
  /// Returns the local path on success. Costs one 250-byte packet to find out:
  /// a station that does not hold it answers `404` and we move on, which is
  /// exactly what section 31.2's budget is for.
  Future<String?> _downloadOverMesh(
      ReleaseInfo release, ReleaseAsset asset) async {
    final self = MeshService.instance.tableCallsign;
    if (self.isEmpty) return null;
    // Only over a lane that can carry the bytes. A `cmd:file` is answered on
    // the advert channel and the FILE travels the bulk lane (25.2.2), and the
    // bulk lane is BLE. Measured on the bench: the desktop, with no Bluetooth,
    // asked a phone it could hear over LAN; the phone held the release and
    // said 202 in 200 ms; and with no lane for the bytes the desktop then sat
    // on that 202 for the transfer's whole timeout. So: our radio must be on,
    // and the station must have declared `link:ble` recently (10.6.1) — not
    // merely be a callsign we have archived a packet from.
    if (!await _ble5Active()) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    final stations = XprsCatchup.instance.stationsInEarshot().where((c) {
      final st = XprsMonitor.instance.stations[c.toUpperCase()];
      return st != null &&
          st.declaredBearersFresh(now, meshEvidenceMs).contains('ble');
    }).toList();
    if (stations.isEmpty) return null;

    status.value = UpdateStatus.downloading;
    progress.value = 0;
    error = null;
    lastSource = 'xprs';
    UpdateNative.serviceStart('Fetching XPRS ${release.version} over the mesh');
    try {
      for (final station in stations) {
        final dot = asset.name.lastIndexOf('.');
        phase.value = 'Asking $station over the mesh';
        final path = await XprsFileFetch.instance.fetch(
          archiver: station,
          shaHex: asset.sha256,
          selfCallsign: NostrCrypto.bareCallsign(self),
          ext: dot >= 0 ? asset.name.substring(dot + 1) : '',
          // Land it where the installer expects, as a file: an APK that became
          // a database blob would have to be written back out to be installed.
          destDir: await UpdateNative.supportDir(),
          // Seconds to say 202, not the transfer's hour: a station that does
          // not hold the release is asked and left behind, never waited on.
          acceptWithin: meshAcceptWithin,
        );
        if (path == null) continue; // 404 / refused / timed out: try the next
        await _markReady(path, release.version);
        LogService.instance.add(
            'update: ${release.version} arrived from $station over the mesh');
        return path;
      }
      lastSource = null;
      status.value = UpdateStatus.checking;
      return null;
    } catch (e) {
      lastSource = null;
      status.value = UpdateStatus.checking;
      return null;
    } finally {
      UpdateNative.serviceStop();
    }
  }

  /// Try to fetch [asset] by its content address over Reticulum.
  ///
  /// Returns false (quietly, leaving the status untouched) when no provider
  /// answers in time, so the caller can fall back to HTTPS. The bounded wait
  /// matters: a phone with no mirror in reach must not sit here.
  ///
  /// KNOWN COST, stated rather than hidden: the content-addressed fetch returns
  /// the artifact as one Uint8List, so this puts ~60 MB on the heap for the
  /// duration of one user-initiated download. Fixing it properly means a
  /// stream-to-disk fetch down in the transfer layer (the ranged piece path
  /// already exists); until then the DownloadManager path above is the one that
  /// carries the mirror's own traffic, and it never holds a byte.
  Future<bool> _downloadOverReticulum(
      ReleaseInfo release, ReleaseAsset asset) async {
    final folder = release.isPrerelease ? _betaFolder : _stableFolder;
    final shaHex = asset.sha256.toLowerCase();
    final dot = asset.name.lastIndexOf('.');
    final ext = dot >= 0 ? asset.name.substring(dot + 1) : '';
    status.value = UpdateStatus.downloading;
    progress.value = 0;
    error = null;
    lastSource = 'reticulum';
    UpdateNative.serviceStart('Fetching XPRS ${release.version} over Reticulum');
    try {
      // An always-on archiver already holds every release it mirrors, verified at
      // ingest. The DHT probe below asks for OTHER providers by design, so
      // without this a mirror that was the only holder concluded nobody had
      // it and went to the web for bytes sitting on its own disk.
      final mine = UpdateMirrorService.instance.pathForSha(shaHex);
      if (mine != null) {
        phase.value = 'Held by this station\'s mirror';
        final dir = await UpdateNative.supportDir();
        final dest = '$dir${pathSeparator}${asset.name}';
        await fs.file(mine).copy(dest);
        lastSource = 'mirror';
        await _markReady(dest, release.version);
        LogService.instance
            .add('update: ${release.version} taken from our own mirror');
        return true;
      }
      // Is there anybody to fetch FROM? The fetch's timeout is sized for
      // moving the bytes, and with no always-on archiver holding this release it
      // spent all five minutes learning that nobody did -- after the mesh had
      // already spent its share. Ask the DHT the cheap question first.
      phase.value = 'Looking for an always-on archiver holding ${release.version}';
      final providers = await RnsService.instance
          .contentProviderCount(shaHex, timeout: providerProbeTimeout);
      if (providers == 0) {
        LogService.instance.add(
            'update: no always-on archiver holds ${release.version} yet — web');
        lastSource = null;
        status.value = UpdateStatus.checking;
        return false;
      }
      phase.value =
          'Fetching from $providers always-on archiver${providers == 1 ? '' : 's'}';
      // Show what is arriving. The fetch reports pieces (or bytes) as they
      // land; a bar that sat at 0% for the whole transfer is what "not
      // starting" looked like from the outside.
      final shaB = _hexBytes(shaHex);
      // Lives only while a download the user started is in flight, cancelled
      // in the finally below: it costs nothing per hour with the screen off
      // because it never exists then.
      final ticker = Timer.periodic(const Duration(milliseconds: 500), (_) { // arch-ignore: no-sub-minute-poll bounded to one user-initiated download, cancelled in finally
        if (shaB == null) return;
        final pr = RnsService.instance.fileFetchProgress(shaB);
        if (pr != null && pr.total > 0) progress.value = pr.received / pr.total;
      });
      Uint8List? bytes;
      try {
        bytes = await RnsService.instance.folderFetchBytes(folder, shaHex,
            ext: ext,
            timeout: reticulumTimeoutFor(asset.size),
            size: asset.size);
      } finally {
        ticker.cancel();
      }
      if (bytes == null || bytes.isEmpty) {
        lastSource = null;
        status.value = UpdateStatus.checking;
        return false;
      }
      // Content-addressed already, but a mismatch here would mean handing the
      // installer something nobody vouched for. Assert it.
      final got = crypto.sha256.convert(bytes).toString();
      if (got != shaHex) {
        error = 'Update failed integrity check (sha mismatch)';
        status.value = UpdateStatus.error;
        return false;
      }
      final path = await UpdateNative.writeBytes(asset.name, bytes, (r, t) {
        if (t > 0) progress.value = r / t;
      });
      if (path == null) {
        error = 'Could not write the update to disk';
        status.value = UpdateStatus.error;
        return false;
      }
      LogService.instance.add(
          'update: ${release.version} fetched over Reticulum (${bytes.length} B)');
      await _markReady(path, release.version);
      return true;
    } catch (e) {
      lastSource = null;
      status.value = UpdateStatus.checking;
      return false;
    } finally {
      UpdateNative.serviceStop();
    }
  }

  // ── Android DownloadManager path ────────────────────────────────────

  /// Enqueue [asset] with the system DownloadManager, persist the job so it can
  /// be re-attached later, and start mirroring its progress. A job already
  /// running for this very artifact is re-attached, not restarted: the
  /// DownloadManager resumes it where it stopped.
  Future<bool> _downloadViaManager(ReleaseInfo release, ReleaseAsset asset,
      {required bool overMetered}) async {
    status.value = UpdateStatus.downloading;
    progress.value = 0;
    error = null;
    final prev = await _activeDownloadId();
    if (prev != null) {
      final p = await SharedPreferences.getInstance();
      final same = p.getString(_kDlVersion) == release.version &&
          p.getString(_kDlName) == asset.name;
      final r = await UpdateNative.pollDownload(prev);
      final st = (r['status'] as String?) ?? 'unknown';
      final reason = (r['reason'] as num?)?.toInt() ?? 0;
      final alive = st == 'pending' ||
          st == 'running' ||
          st == 'paused' ||
          st == 'success';
      // A person asking now gets it now: an automatic job held back for Wi-Fi
      // is replaced by one that may use mobile data.
      final heldForWifi = overMetered &&
          (st == 'pending' ||
              (st == 'paused' && (reason == 2 || reason == 3)));
      if (same && alive && !heldForWifi) {
        return _trackManagedDownload(prev, release, asset);
      }
      await UpdateNative.removeDownload(prev);
      await _clearActiveDownload();
    }
    final id = await UpdateNative.enqueueDownload(
        asset.url, asset.name, 'XPRS ${release.version}',
        overMetered: overMetered);
    if (id == null) {
      error = 'Could not start the download';
      status.value = UpdateStatus.error;
      return false;
    }
    await _persistActiveDownload(id, release, asset);
    return _trackManagedDownload(id, release, asset);
  }

  static bool get _onScreen =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  /// Poll a DownloadManager job to completion, mirroring bytes into [progress]
  /// and verifying the finished file before marking it installable.
  ///
  /// The DownloadManager does the work in its own process; this only reads its
  /// counters. Every second while someone can see the bar, every 30 s with the
  /// screen off, and once a minute while the job waits for a network.
  Future<bool> _trackManagedDownload(
      int id, ReleaseInfo release, ReleaseAsset asset) async {
    if (_tracking) return false;
    _tracking = true;
    try {
      while (true) {
        final r = await UpdateNative.pollDownload(id);
        final st = (r['status'] as String?) ?? 'unknown';
        final downloaded = (r['downloaded'] as num?)?.toInt() ?? 0;
        // DownloadManager reports total -1 until it learns Content-Length; fall
        // back to the feed's advertised size so the bar still moves.
        final reported = (r['total'] as num?)?.toInt() ?? -1;
        final total = reported > 0 ? reported : asset.size;
        if (st == 'pending' || st == 'running' || st == 'paused') {
          if (total > 0) {
            progress.value = (downloaded / total).clamp(0.0, 1.0);
          }
          status.value = UpdateStatus.downloading;
          final reason = (r['reason'] as num?)?.toInt() ?? 0;
          final waiting = st != 'running';
          phase.value = !waiting
              ? ''
              : reason == 3
                  ? tr('updates.phase.wifi')
                  : tr('updates.phase.network');
          final delay = waiting
              ? (_onScreen ? const Duration(seconds: 3) : const Duration(minutes: 1))
              : (_onScreen ? const Duration(seconds: 1) : const Duration(seconds: 30));
          await Future<void>.delayed(delay);
          continue;
        }
        phase.value = '';
        if (st == 'success') {
          final path = r['localPath'] as String?;
          if (path == null) {
            return _failManaged(
                id, 'Download finished but the file could not be found');
          }
          final ok = await UpdateNative.verifyFile(path,
              expectedSize: asset.size, expectedSha: asset.sha256);
          if (!ok) {
            return _failManaged(id, 'Update failed its integrity check');
          }
          lastSource ??= 'https';
          // Verified and remembered: the job record is no longer needed, and
          // keeping it would hash the file again at every start.
          await _clearActiveDownload();
          await _markReady(path, release.version);
          return true;
        }
        // 'failed' / 'unknown'
        return _failManaged(id, 'Download failed');
      }
    } finally {
      _tracking = false;
    }
  }

  bool _failManaged(int id, String message) {
    error = message;
    status.value = UpdateStatus.error;
    // Fire-and-forget cleanup of the (partial) job.
    UpdateNative.removeDownload(id);
    _clearActiveDownload();
    return false;
  }

  /// Re-attach to a DownloadManager job left running/finished by a previous
  /// session (panel closed, app backgrounded or relaunched). Safe to call on
  /// every Updates panel open and at startup; no-ops when nothing is pending.
  Future<void> resumeActiveDownload() async {
    if (!supported || fdroidOnly || _tracking || !UpdateNative.hasDownloadManager) {
      return;
    }
    final p = await SharedPreferences.getInstance();
    final id = p.getInt(_kDlId);
    if (id == null) return;
    final version = p.getString(_kDlVersion) ?? '';
    final asset = ReleaseAsset(
      name: p.getString(_kDlName) ?? '',
      url: '',
      size: p.getInt(_kDlSize) ?? 0,
      sha256: p.getString(_kDlSha) ?? '',
    );
    final release = ReleaseInfo(
      version: version,
      tagName: 'v$version',
      isPrerelease: p.getBool(_kDlPre) ?? false,
      assets: const [],
    );
    if (version.isEmpty ||
        readyIsStale(readyVersion: version, running: kAppVersion)) {
      // Installed meanwhile (or never named): nothing left to fetch.
      await UpdateNative.removeDownload(id);
      await _clearActiveDownload();
      return;
    }
    final r = await UpdateNative.pollDownload(id);
    final st = (r['status'] as String?) ?? 'unknown';
    if (st == 'unknown') {
      // The record is stale (job evicted); forget it silently.
      await _clearActiveDownload();
      return;
    }
    // Hand off to the tracker (handles running → progress, success → verify).
    unawaited(_trackManagedDownload(id, release, asset));
  }

  Future<int?> _activeDownloadId() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kDlId);
  }

  Future<void> _persistActiveDownload(
      int id, ReleaseInfo release, ReleaseAsset asset) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kDlId, id);
    await p.setString(_kDlVersion, release.version);
    await p.setString(_kDlName, asset.name);
    await p.setInt(_kDlSize, asset.size);
    await p.setString(_kDlSha, asset.sha256);
    await p.setBool(_kDlPre, release.isPrerelease);
  }

  Future<void> _clearActiveDownload() async {
    final p = await SharedPreferences.getInstance();
    for (final k in [_kDlId, _kDlVersion, _kDlName, _kDlSize, _kDlSha, _kDlPre]) {
      await p.remove(k);
    }
  }

  /// Apply the downloaded artifact. On Android, ensures the install permission
  /// first (opens settings if missing). Quits the app on desktop to swap files.
  ///
  /// The download stays on record until the new version runs: the person may
  /// cancel the system installer and tap Install again.
  Future<bool> install([ReleaseInfo? release]) async {
    if (!supported || fdroidOnly || _downloadedPath == null) return false;
    final platform = currentUpdatePlatform();
    if (platform == UpdatePlatform.android && !await UpdateNative.canInstall()) {
      await UpdateNative.openInstallSettings();
      // The download stays ready: Install works once the permission is given.
      error = tr('updates.allow_install');
      return false;
    }
    error = null;
    await UpdateNative.apply(platform, _downloadedPath!);
    return true;
  }

}
