/*
 * Cross-wapp event broker
 *
 * Singleton routing pub/sub between WASM modules. Each [WappEngine]
 * registers an opaque engineId on load, subscribes to topics on demand
 * (via hal_event_subscribe), and drains pending events from its private
 * queue (via hal_event_available + hal_event_recv).
 *
 * publish() fans out an event to every engine that is subscribed to the
 * topic, appending to each engine's queue. It also fires a
 * [WappEventBridgeEvent] on the host [EventBus] so Dart-side observers
 * can watch wapp pub/sub traffic for debugging or bridging.
 */

import 'dart:collection';

import '../services/event_bus.dart';

class _PendingEvent {
  final String topic;
  final String data;
  _PendingEvent(this.topic, this.data);
}

class _EngineState {
  final Set<String> subscribedTopics = {};
  final Queue<_PendingEvent> queue = Queue();
}

class WappEventBroker {
  WappEventBroker._();
  static final WappEventBroker instance = WappEventBroker._();

  /// Cap a single engine's queue so a runaway publisher cannot drown the
  /// host. Drops the oldest event when full.
  static const int maxQueuePerEngine = 1024;

  final Map<String, _EngineState> _engines = {};

  /// Wake an engine that has just been given an event.
  ///
  /// Without this, `publish` only queues and the wapp finds the event on its
  /// next `module_tick` -- which is why every wapp that wants to be
  /// responsive declares a short interval and burns CPU asking "anything
  /// yet?" sixty times a minute. Measured on the bench: 18.8% of the main
  /// isolate across the background wapps, almost all of it finding nothing.
  ///
  /// With a wake, arrival drives the tick instead of the clock, and a wapp's
  /// declared interval becomes what it is supposed to be -- a floor for
  /// housekeeping, not a latency budget.
  ///
  /// Set by the host (page engine and background manager). One slot per
  /// engine id, because only the owner of an engine can tick it.
  final Map<String, void Function()> _wakers = {};

  void setWaker(String engineId, void Function() wake) =>
      _wakers[engineId] = wake;

  void clearWaker(String engineId) => _wakers.remove(engineId);

  /// Register a wapp engine. Idempotent.
  void registerEngine(String engineId) {
    _engines.putIfAbsent(engineId, _EngineState.new);
  }

  /// Unregister and drop all queued events + subscriptions for [engineId].
  void unregisterEngine(String engineId) {
    _engines.remove(engineId);
    _wakers.remove(engineId);
  }

  /// Subscribe [engineId] to [topic]. Returns 0 on success, -1 if the
  /// engine is unknown.
  int subscribe(String engineId, String topic) {
    final state = _engines[engineId];
    if (state == null) return -1;
    state.subscribedTopics.add(topic);
    return 0;
  }

  /// Unsubscribe [engineId] from [topic]. Returns 0 on success, -1 if
  /// the engine is unknown.
  int unsubscribe(String engineId, String topic) {
    final state = _engines[engineId];
    if (state == null) return -1;
    state.subscribedTopics.remove(topic);
    return 0;
  }

  /// Publish [data] on [topic]. Delivered to every engine that has
  /// subscribed to the exact topic string, including [fromEngineId]
  /// itself if it is subscribed. Returns the number of engines notified.
  int publish(String fromEngineId, String topic, String data) {
    var notified = 0;
    final woken = <String>[];
    for (final entry in _engines.entries) {
      final state = entry.value;
      if (!state.subscribedTopics.contains(topic)) continue;
      if (state.queue.length >= maxQueuePerEngine) {
        state.queue.removeFirst();
      }
      state.queue.add(_PendingEvent(topic, data));
      notified++;
      woken.add(entry.key);
    }
    // Wake AFTER queueing all of them, so an engine that ticks synchronously
    // inside its waker sees every event this publish produced rather than
    // racing the loop that is still filling other queues.
    for (final id in woken) {
      try {
        _wakers[id]?.call();
      } catch (e) {
        EventBus().fire(WappEventBridgeEvent(
          fromEngineId: id, topic: 'system.error', data: 'wake failed: $e'));
      }
    }
    EventBus().fire(WappEventBridgeEvent(
      fromEngineId: fromEngineId,
      topic: topic,
      data: data,
    ));
    return notified;
  }

  /// Bytes-of-data of the next pending event for [engineId], or 0 if
  /// the queue is empty / engine unknown. Wapps poll this from
  /// hal_event_available before calling [recv].
  int availableSize(String engineId) {
    final state = _engines[engineId];
    if (state == null || state.queue.isEmpty) return 0;
    return state.queue.first.data.length;
  }

  /// Pop the next pending event for [engineId] or return null if none.
  ({String topic, String data})? recv(String engineId) {
    final state = _engines[engineId];
    if (state == null || state.queue.isEmpty) return null;
    final ev = state.queue.removeFirst();
    return (topic: ev.topic, data: ev.data);
  }

  // ── Inspection helpers (debug API / future task monitor UI) ────────

  int subscriptionCount(String engineId) =>
      _engines[engineId]?.subscribedTopics.length ?? 0;

  int queueDepth(String engineId) => _engines[engineId]?.queue.length ?? 0;

  Iterable<String> registeredEngines() => _engines.keys;
}
