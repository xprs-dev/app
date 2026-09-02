/*
 * The core telling a wapp its state moved — the half of the bus that was
 * missing.
 *
 * The bus carried packets and nothing else, which is why every wapp that drew
 * core state polled: the station table, the Reticulum graph, the mesh
 * topology, the archive's counters. None of them is a packet, so none of them
 * had a topic, so the only way to see a change was to ask on a timer — xprs
 * every 3s, mesh every 2s, bluetooth every 2s, archiver every 5s, forever,
 * whether or not anything had happened.
 *
 * Two properties carry the whole design, and both are here: a change is
 * ANNOUNCED, and a burst is announced ONCE.
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/services/receive/core_state.dart';
import 'package:xprs/wapp/wapp_event_broker.dart';

/// A listener, because silence is the default: the core arms nothing for a
/// topic nobody watches, which is what makes an idle device idle.
void listen(String topic) {
  WappEventBroker.instance.registerEngine('t');
  WappEventBroker.instance.subscribe('t', topic);
}

void main() {
  setUp(CoreState.debugReset);
  tearDown(() {
    CoreState.debugReset();
    WappEventBroker.instance.unregisterEngine('t');
  });

  test('with nobody subscribed, a change announces nothing', () {
    // The rule the rest of these tests set up around. A core that has to
    // deliver to nobody must not even arm a timer to do it.
    final seen = <String>[];
    CoreState.onPublish = (t, _) => seen.add(t);
    for (var i = 0; i < 50; i++) {
      CoreState.instance.changed(CoreState.monitor);
    }
    CoreState.instance.flushForTest();
    expect(seen, isEmpty);
    expect(CoreState.instance.revisionOf(CoreState.monitor), 50,
        reason: 'the revision still moves, so a later subscriber is not lied to');
  });

  test('a change is announced, with the revision it moved to', () {
    listen(CoreState.monitor);
    final seen = <(String, int)>[];
    CoreState.onPublish = (t, r) => seen.add((t, r));

    CoreState.instance.changed(CoreState.monitor);
    expect(seen, isEmpty, reason: 'nothing goes out before the window closes');

    CoreState.instance.flushForTest();
    expect(seen, [(CoreState.monitor, 1)]);
  });

  test('a burst is ONE announcement, not one per change', () {
    // The case this exists for: a hub dumps its whole cached announce table on
    // connect, hundreds inside a second. A reader re-reads the entire graph on
    // each notification, so one-per-change would cost more than the poll it
    // replaces.
    listen(CoreState.rnsGraph);
    final seen = <(String, int)>[];
    CoreState.onPublish = (t, r) => seen.add((t, r));

    for (var i = 0; i < 200; i++) {
      CoreState.instance.changed(CoreState.rnsGraph);
    }
    CoreState.instance.flushForTest();

    expect(seen.length, 1);
    expect(seen.single.$1, CoreState.rnsGraph);
    expect(seen.single.$2, 200, reason: 'the revision counts every change');
    expect(CoreState.coalesced, 199);
  });

  test('topics do not collapse into each other', () {
    for (final t in CoreState.topics) {
      listen(t);
    }
    final seen = <String>[];
    CoreState.onPublish = (t, _) => seen.add(t);
    for (final t in CoreState.topics) {
      CoreState.instance.changed(t);
      CoreState.instance.changed(t); // twice each, to prove per-topic coalescing
    }
    CoreState.instance.flushForTest();
    expect(seen.toSet(), CoreState.topics.toSet());
    expect(seen.length, CoreState.topics.length);
    for (final t in CoreState.topics) {
      expect(CoreState.instance.revisionOf(t), 2);
    }
  });

  test('a wapp datagram topic is named after the wapp, not shared', () {
    // Two wapps' private protocols are not each other's business, so the
    // topic carries the tag rather than being one queue everybody watches.
    expect(CoreState.datagram('circles'), 'core.datagram.circles');
    expect(CoreState.datagram('chat'), isNot(CoreState.datagram('circles')));
    expect(CoreState.topics, isNot(contains(CoreState.datagram('circles'))));
  });

  test('a quiet core publishes nothing at all', () {
    final seen = <String>[];
    CoreState.onPublish = (t, _) => seen.add(t);
    CoreState.instance.flushForTest();
    expect(seen, isEmpty);
    expect(CoreState.published, 0,
        reason: 'the whole point: silence costs nothing');
  });
}
