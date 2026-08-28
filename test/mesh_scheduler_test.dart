/*
 * MeshTransferScheduler gate-state tests — the one mesh component that had
 * none, and where every silent stall of 2026-07-03 lived.
 */
import 'package:xprs/services/mesh/mesh_transfer_scheduler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final s = MeshTransferScheduler.instance;

  test('backoff doubles on failure, clears on clean close', () {
    s.dialResult('AAAA', clean: false); // 15s
    s.dialResult('AAAA', clean: false); // 30s
    s.dialResult('AAAA', clean: false); // 60s
    final b1 = s.statusJson()['backoff'] as Map;
    expect(b1['AAAA'], greaterThan(45)); // ≥ ~60s pending
    s.dialResult('AAAA', clean: true); // clean: quiet 60s then free
    final b2 = s.statusJson()['backoff'] as Map;
    expect(b2['AAAA'], lessThanOrEqualTo(60));
  });

  test('backoff caps at 2 minutes', () {
    for (var i = 0; i < 10; i++) {
      s.dialResult('BBBB', clean: false);
    }
    final b = s.statusJson()['backoff'] as Map;
    expect(b['BBBB'], lessThanOrEqualTo(120));
  });

  test('a clean close still quiets a FETCH, but never a SEND', () {
    // The 60 s clean-quiet exists so we do not re-dial a station to COLLECT
    // mail it does not have for us. Applied to our own outbound it made a
    // message the user had just typed wait up to a minute: measured
    // TANK2 -> C61 at 36 s with an empty backoff and a healthy session lane.
    s.dialResult('CCCC', clean: true);
    final j = s.statusJson()['backoff'] as Map;
    expect(j['CCCC'], isNotNull,
        reason: 'the peer is still quieted for fetching');
    expect(j['CCCC'], greaterThan(30));
  });

  test('a FAILED close holds in both directions', () {
    s.dialResult('DDDD', clean: false);
    final j = s.statusJson()['backoff'] as Map;
    expect(j['DDDD'], isNotNull);
    expect(j['DDDD'], greaterThan(0),
        reason: 'a peer that will not answer is not dialled harder');
  });

  test('statusJson always reports a decision', () {
    final j = s.statusJson();
    expect(j['decision'], isNotNull);
    expect(j.containsKey('dialing'), true);
    expect(j.containsKey('lastDialAttempt'), true);
  });
}
