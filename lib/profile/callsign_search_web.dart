/*
 * The web build has no isolates, and a search on its only thread would
 * freeze the page (docs/performance.md 8.1), so there it says it cannot.
 */
import '../services/i18n/core_i18n.dart';
import 'callsign_key_source.dart';

class IsolateCallsignSource implements CallsignKeySource {
  @override
  final String prefix;
  IsolateCallsignSource(this.prefix);

  @override
  Future<void> start(String pattern, int length,
      void Function(int, List<PickedCallsign>) onBatch,
      void Function(String) onDone) async {
    onDone(tr('onboarding.vanity.unavailable'));
  }

  @override
  void stop() {}
}
