import 'dart:async';
import 'dart:collection';

import 'package:flutter/widgets.dart';

import '../profile/profile_service.dart';
import '../profile/storage_paths.dart';

/// The persistent half of notification dedupe: every tag that has ever been
/// announced to the user, per profile. [NotificationService.show] consults
/// this before announcing a tagged notification, which is what keeps replayed
/// events (wapps re-subscribe and re-ingest their backlog on every start)
/// from resurrecting already-seen notifications after a restart.
///
/// One tag per line in notifications/announced.txt, oldest first. FIFO-capped:
/// a tag that ages out of the cap can in principle announce once more, but the
/// cap is far above the notification history (300) and the mail seen-ring.
class AnnouncedTagsStore with WidgetsBindingObserver {
  AnnouncedTagsStore._();
  static final AnnouncedTagsStore instance = AnnouncedTagsStore._();

  static const int maxTags = 4000;
  static const String _file = 'notifications/announced.txt';

  final LinkedHashSet<String> _tags = LinkedHashSet<String>();
  bool _initialised = false;
  bool _loaded = false;
  Completer<void> _ready = Completer<void>();
  Timer? _saveDebounce;

  /// True once the active profile's tag set has been read (or failed to read
  /// and defaulted to empty). Before that, [NotificationService] buffers
  /// tagged notifications instead of guessing.
  bool get loaded => _loaded;

  /// Completes when [loaded] flips true; re-armed on every profile switch.
  Future<void> get ready => _ready.future;

  void init() {
    if (_initialised) return;
    _initialised = true;
    // A tag that never reaches disk is a notification that announces itself
    // again after the next start. Android freezes or kills a backgrounded
    // process without warning, so the pause edge is the last chance to write.
    // An observer, not a timer: it costs nothing while the app runs.
    WidgetsBinding.instance.addObserver(this);
    ProfileService.instance.activeProfileNotifier.addListener(_reload);
    unawaited(_load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    _saveDebounce?.cancel();
    _saveDebounce = null;
    unawaited(_persist());
  }

  bool contains(String tag) => _tags.contains(tag);

  void add(String tag) {
    if (tag.isEmpty) return;
    _tags.add(tag);
    while (_tags.length > maxTags) {
      _tags.remove(_tags.first);
    }
    // Arm ONCE, never restart. Cancel-and-restart meant a burst arriving
    // faster than one tag a second pushed the write forever -- and a backlog
    // replay at startup is exactly such a burst, so the file that is supposed
    // to stop the replay was the file the replay prevented from being written.
    // Arming once bounds the loss at one second while keeping the write rate
    // at <=1/s, which is the point of the debounce: _persist rewrites up to
    // 4000 lines, and on an encrypted profile that is a re-encrypt.
    _saveDebounce ??= Timer(const Duration(seconds: 1), () {
      _saveDebounce = null;
      unawaited(_persist());
    });
  }

  void _reload() {
    // An armed timer would fire AFTER the switch and _persist resolves the
    // profile root at fire time -- writing this profile's tags into the next
    // one. A bounded loss beats cross-profile contamination.
    _saveDebounce?.cancel();
    _saveDebounce = null;
    _loaded = false;
    _ready = Completer<void>();
    unawaited(_load());
  }

  Future<void> _load() async {
    _tags.clear();
    try {
      final raw = await activeProfileRoot().readString(_file);
      if (raw != null) {
        for (final line in raw.split('\n')) {
          final tag = line.trim();
          if (tag.isNotEmpty) _tags.add(tag);
        }
      }
    } catch (_) {
      // Locked/absent profile storage: run with an empty set rather than
      // blocking notifications forever.
    }
    _loaded = true;
    if (!_ready.isCompleted) _ready.complete();
  }

  Future<void> _persist() async {
    try {
      final root = activeProfileRoot();
      await root.createDirectory('notifications');
      await root.writeString(_file, _tags.join('\n'));
    } catch (_) {}
  }

  /// Test hook: pretend the (empty) set finished loading, so show() consults
  /// the guard instead of buffering. Tests have no profile storage to load.
  @visibleForTesting
  void markLoadedForTest() {
    _loaded = true;
    if (!_ready.isCompleted) _ready.complete();
  }

  @visibleForTesting
  void reset() {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    _tags.clear();
    if (_initialised) WidgetsBinding.instance.removeObserver(this);
    _initialised = false;
    _loaded = false;
    _ready = Completer<void>();
    ProfileService.instance.activeProfileNotifier.removeListener(_reload);
  }
}
