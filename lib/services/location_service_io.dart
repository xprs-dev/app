// geolocator-backed device location for the hal_sensor_gps_* HAL.
//
// Fetches the current position once (and then follows updates) on first use,
// caching the latest lat/lon. The HAL reads the cache synchronously as
// fixed-point degrees × 1e7. Any failure (no GPS, denied permission, no
// platform plugin — e.g. desktop Linux) leaves the cache null so callers fall
// back to their configured position.

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:geolocator/geolocator.dart';

import 'power_state.dart';

class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  double? _lat;
  double? _lon;
  bool _started = false;
  StreamSubscription<Position>? _sub;
  DateTime _lastRead = DateTime.now();
  Timer? _idleCheck;

  /// Stop the stream when nothing has read a fix for this long. GPS is the
  /// most expensive sensor on the phone and this cache is read by whichever
  /// wapp happens to want a coordinate; once that wapp stops asking, the
  /// stream was still running — all night, at best accuracy, with no distance
  /// filter. The next [ensureStarted] (or [latE7] read) brings it back.
  static const Duration _idleStop = Duration(minutes: 5);

  /// Latest fix as fixed-point degrees × 1e7 (fits int32 for ±90/±180), or
  /// null when there is no fix.
  int? get latE7 {
    _touch();
    return _lat == null ? null : (_lat! * 1e7).round();
  }

  int? get lonE7 {
    _touch();
    return _lon == null ? null : (_lon! * 1e7).round();
  }

  /// Somebody read the cache — the stream is earning its keep.
  void _touch() {
    _lastRead = DateTime.now();
    if (!_started) ensureStarted();
  }

  /// Kick off permission + position acquisition once. Fire-and-forget — the
  /// synchronous HAL just reads whatever is cached so far.
  void ensureStarted() {
    if (_started) return;
    _started = true;
    unawaited(_start());
  }

  Future<void> _start() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      // NEVER prompt from here. This runs when a background wapp first reaches
      // for GPS — which, on a fresh install, is moments after the user picked a
      // callsign. That is the ambush prompt we set out to remove. Location is
      // offered on the permissions intro like everything else; if it was not
      // granted there, we simply have no fix, and callers fall back.
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        debugPrint('LocationService: not granted — no fix (asked in onboarding)');
        return;
      }
      try {
        _set(await Geolocator.getCurrentPosition());
      } catch (_) {
        // No immediate fix — the stream below may still deliver one.
      }
      // Medium accuracy and a 25 m filter: this cache feeds position fields
      // and map centring, not turn-by-turn navigation. Best-accuracy with no
      // distance filter is a continuous GNSS fix — the default this used to
      // take — for a value that is cosmetic between one street corner and the
      // next (docs/performance.md 4.2).
      _sub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          distanceFilter: 25,
        ),
      ).listen(_set, onError: (_) {});
      _idleCheck ??= Timer.periodic(const Duration(minutes: 1), (_) => _idle());
    } catch (e) {
      // No location plugin on this platform (desktop Linux has none) or some
      // other failure — leave coords null so callers fall back.
      debugPrint('LocationService: unavailable: $e');
    }
  }

  /// Fetch a fresh fix on demand. This one MAY prompt: it runs only when the
  /// user taps "centre on my location", and a prompt that answers a tap the user
  /// just made is expected, not an ambush. Returns (lat, lon) or null on any
  /// failure — no GPS, denied permission, or no location plugin on this platform
  /// (e.g. desktop Linux).
  Future<({double lat, double lon})?> currentPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      final p = await Geolocator.getCurrentPosition();
      _set(p);
      return (lat: p.latitude, lon: p.longitude);
    } catch (e) {
      debugPrint('LocationService.currentPosition: $e');
      return null;
    }
  }

  /// Stop the stream when nobody is reading it, or when the battery tier says
  /// the phone is scraping by. Never stops it while a fix is being consumed.
  void _idle() {
    if (_sub == null) return;
    final idle = DateTime.now().difference(_lastRead) >= _idleStop;
    final low = PowerState.instance.tier.value == PowerTier.low;
    if (!idle && !low) return;
    debugPrint('LocationService: stopping GPS stream '
        '(${low ? 'low battery' : 'unread for ${_idleStop.inMinutes} min'})');
    _sub?.cancel();
    _sub = null;
    _idleCheck?.cancel();
    _idleCheck = null;
    _started = false; // the next read starts it again
  }

  void _set(Position p) {
    _lat = p.latitude;
    _lon = p.longitude;
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
  }
}
