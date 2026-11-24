/*
 * What CallsignPickerPage asks its key source for, kept apart from any
 * isolate code so the web build (no dart:isolate) compiles the same types.
 */

/// A callsign the person chose. [nsec] is empty when the key stays where it
/// was made (the core's group-key pool).
class PickedCallsign {
  final String callsign;
  final String npub;
  final String nsec;
  const PickedCallsign({required this.callsign, this.npub = '', this.nsec = ''});
}

/// Where the keys behind the offered callsigns come from.
abstract class CallsignKeySource {
  /// The callsign's kind: `X1` a person, `X3` a station, `X5` a group.
  String get prefix;

  /// Look for callsigns whose key part contains [pattern], [length]
  /// characters long, calling [onBatch] with how many keys were tried and the
  /// matches, until [stop]. [onDone] says the source gave up, with why.
  ///
  /// [onBatch] is also the screen's clock: a source calls it at least every
  /// half second while it searches, matches or not, so the page needs no
  /// timer of its own (docs/performance.md 6.5).
  Future<void> start(String pattern, int length,
      void Function(int tried, List<PickedCallsign> matches) onBatch,
      void Function(String why) onDone);

  void stop();
}
