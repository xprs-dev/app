import 'package:flutter/foundation.dart' show ValueNotifier;

import 'preferences_service.dart';

/// Which wapps the launcher surfaces, and where.
///
/// Two home-screen slots — the rectangular module bars and the icon dock — each
/// prefer the user's explicit pins and otherwise fall back to a most-used
/// ranking driven by [increment]. Callers top the result up from the installed
/// list, so a slot is never short just because the user has launched few wapps.
class LaunchCountStore {
  LaunchCountStore._();
  static final LaunchCountStore instance = LaunchCountStore._();

  /// Bumped whenever a pin changes, so the home slots rebuild immediately
  /// instead of waiting for the next launcher rescan.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  Future<void> increment(String wappId) async {
    final prefs = await PreferencesService.instance();
    await prefs.incrementWappLaunch(wappId);
  }

  Future<bool> isPinnedToModules(String wappId) async =>
      (await PreferencesService.instance()).isPinnedToModules(wappId);

  Future<bool> isPinnedToDock(String wappId) async =>
      (await PreferencesService.instance()).isPinnedToDock(wappId);

  Future<void> setPinnedToModules(String wappId, bool pinned) async {
    await (await PreferencesService.instance())
        .setPinnedToModules(wappId, pinned);
    revision.value++;
  }

  Future<void> setPinnedToDock(String wappId, bool pinned) async {
    await (await PreferencesService.instance()).setPinnedToDock(wappId, pinned);
    revision.value++;
  }

  Future<List<String>> topN(int n) async {
    final prefs = await PreferencesService.instance();
    return prefs.topLaunchedWapps(n);
  }

  /// The three wapps a person needs to find first: Status (the `social`
  /// install), Chat and Mesh. They hold the module bars until the user pins
  /// something of their own, so a fresh install always shows them, and a
  /// wapp opened often does not push one of them off the home screen; the
  /// dock below is where most-used wapps go.
  ///
  /// Every id here must also be in `_kDefaultSeedNames` (launcher/seeding.dart)
  /// or it is never installed on a fresh profile, and naming it here does
  /// nothing at all: the resolver silently skips ids it cannot find.
  static const List<String> kDefaultModuleWapps = [
    'social',
    'chat',
    'mesh',
  ];

  /// Pinned module bars, else [kDefaultModuleWapps] first and the most-used
  /// wapps after them.
  Future<List<String>> preferredModules(int n) => _preferred(n, dock: false);

  /// Pinned dock icons, or the most-used wapps when the user pinned none.
  Future<List<String>> preferredDock(int n) => _preferred(n, dock: true);

  Future<List<String>> _preferred(int n, {required bool dock}) async {
    final prefs = await PreferencesService.instance();
    final pinned = dock ? prefs.homeDock : prefs.homeModules;
    if (pinned.isNotEmpty) return pinned.take(n).toList(growable: false);
    final top = prefs.topLaunchedWapps(n);
    if (dock) return top;
    final out = <String>[];
    for (final id in [...kDefaultModuleWapps, ...top]) {
      if (out.length >= n) break;
      if (!out.contains(id)) out.add(id);
    }
    return out;
  }
}
