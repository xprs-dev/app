/*
 * Callsign search off the UI isolate (docs/performance.md 8.1): one worker
 * per search, alive only while the person watches it, killed on stop.
 */
import 'dart:isolate';

import '../util/nostr_key_generator.dart';
import 'callsign_key_source.dart';

/// How long the worker searches before it reports. Each report is the
/// screen's progress tick, so this is also how often the screen redraws.
const int _reportEveryMs = 250;

/// The worker. The owner sends `{pattern, length, prefix}`; this generates
/// keypairs for [_reportEveryMs], replies `{keysGenerated, matches}`, and
/// waits for the next ask, so the search stays stoppable and only runs while
/// somebody is asking.
void callsignSearchIsolate(SendPort mainSendPort) {
  final port = ReceivePort();
  mainSendPort.send(port.sendPort);
  port.listen((message) {
    if (message == 'stop') {
      port.close();
      return;
    }
    if (message is! Map) return;
    final pattern = message['pattern'] as String;
    final length = message['length'] as int;
    // Only the characters after the kind come from the key, so only they are
    // searched: a pattern of "X1" used to match every key there is.
    final prefix = message['prefix'] as String;
    final sw = Stopwatch()..start();
    var generated = 0;
    final matches = <Map<String, String>>[];
    while (sw.elapsedMilliseconds < _reportEveryMs) {
      final keys = NostrKeyGenerator.generateKeyPair(callsignLength: length);
      generated++;
      final tail = keys.callsign.substring(2);
      if (tail.contains(pattern)) {
        matches.add({'npub': keys.npub, 'nsec': keys.nsec, 'callsign': '$prefix$tail'});
      }
    }
    mainSendPort.send({'keysGenerated': generated, 'matches': matches});
  });
}

/// Keys made on their own isolate, handed to the caller with the callsign.
class IsolateCallsignSource implements CallsignKeySource {
  @override
  final String prefix;
  IsolateCallsignSource(this.prefix);

  Isolate? _isolate;
  ReceivePort? _port;
  SendPort? _send;
  bool _on = false;

  @override
  Future<void> start(String pattern, int length,
      void Function(int, List<PickedCallsign>) onBatch,
      void Function(String) onDone) async {
    _on = true;
    final port = ReceivePort();
    _port = port;
    void ask() => _send?.send({'pattern': pattern, 'length': length, 'prefix': prefix});
    port.listen((message) {
      if (message is SendPort) {
        _send = message;
        ask();
      } else if (message is Map && _on) {
        onBatch(message['keysGenerated'] as int, [
          for (final m in (message['matches'] as List))
            PickedCallsign(
              callsign: (m as Map)['callsign'] as String,
              npub: m['npub'] as String,
              nsec: m['nsec'] as String,
            ),
        ]);
        if (_on) ask();
      }
    });
    _isolate = await Isolate.spawn(callsignSearchIsolate, port.sendPort,
        debugName: 'callsign-search');
    // Stopped while it was spawning: nothing else will kill it.
    if (!_on) stop();
  }

  @override
  void stop() {
    _on = false;
    _send?.send('stop');
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _port?.close();
    _port = null;
    _send = null;
  }
}
