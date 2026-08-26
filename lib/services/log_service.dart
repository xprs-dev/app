/*
 * In-memory ring buffer of recent log lines, so the remote-control API
 * (RemoteApiService) can expose them over /api/log. main() pipes Flutter's
 * debugPrint through [add] at startup, so anything the app prints is captured.
 *
 * Pure Dart (no dart:io) — safe to import on web.
 */

/// Build marker — BUMP THIS EVERY BUILD so we can prove from /api/status or
/// /api/log which binary is actually running on the device (a stale reinstall
/// would still report the old tag). Surfaced in RemoteApiService /api/status
/// and logged at startup in main().
const String kXprsBuildTag = 'msgorigin-20260607a';

/// Process-wide recent-log buffer.
class LogService {
  LogService._();
  static final LogService instance = LogService._();

  /// The Dart VM service URI (debug/profile builds), pinned OUTSIDE the ring —
  /// on a busy node the announce flood evicts the boot line within minutes,
  /// and it's exactly what you need hours later to attach to a wedged app.
  /// Served by /api/status.
  String? vmServiceUri;

  static const int _max = 2000;

  /// Per-line cap. Announce/profile log lines can embed multi-KB payloads
  /// (inline base64 avatars in announce app_data) — retaining 2000 of those
  /// held ~50MB of heap on a live node and kept the GC churning. A diagnostic
  /// line's value is in its head; the tail of a blob is noise.
  static const int _maxLineLen = 512;
  final List<String> _lines = <String>[];

  /// Append one line (timestamped). Oldest lines are dropped past [_max].
  /// The last line added, and how many identical ones have been swallowed
  /// since. A repeating fault is one fact however often it repeats.
  String _lastLine = '';
  int _repeats = 0;

  void add(String line) {
    final capped = line.length <= _maxLineLen
        ? line
        : '${line.substring(0, _maxLineLen)}…[+${line.length - _maxLineLen}]';

    // COLLAPSE consecutive duplicates. The ring is bounded in ROWS, which
    // bounds its memory and nothing else: a component stuck in an error loop
    // still pays the allocation and the timestamp for every line, and still
    // pushes every other line in the ring out of it -- so the one buffer that
    // could explain the fault is full of the fault. Measured on a phone: 800
    // identical socket errors in 56 ms, about 14,000 lines a second, which is
    // both an out-of-memory and a log with no history left in it.
    if (capped == _lastLine) {
      _repeats++;
      // Keep the tail honest without growing it: rewrite the last row.
      if (_lines.isNotEmpty) {
        _lines[_lines.length - 1] =
            '${DateTime.now().toIso8601String()}  $capped (x${_repeats + 1})';
      }
      return;
    }
    _lastLine = capped;
    _repeats = 0;
    _lines.add('${DateTime.now().toIso8601String()}  $capped');
    if (_lines.length > _max) {
      _lines.removeRange(0, _lines.length - _max);
    }
  }

  /// The most recent [n] lines (all of them when n <= 0 or n >= length).
  List<String> tail(int n) {
    if (n <= 0 || n >= _lines.length) return List<String>.of(_lines);
    return _lines.sublist(_lines.length - n);
  }

  int get length => _lines.length;
}
