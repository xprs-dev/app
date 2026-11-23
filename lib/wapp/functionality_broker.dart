/*
 * FunctionalityBroker — how one wapp asks another for something it provides
 * (`provides.functionalities` in the provider's manifest), and is answered
 * whenever the provider is ready: at once, or after the provider's own
 * network request has come back.
 *
 * Flow:
 *   1. The caller emits `{"type":"widget.request","widget":"<id>",
 *      "req_id":"<its own>","args":{...}}` via hal_msg_send (the wire keeps
 *      the name `widget.*` from when functionalities were widgets). A page
 *      and a background wapp both forward it to [handleRequest].
 *   2. The broker picks a provider ([FunctionalityRegistry], the person's
 *      preferred one when several) and opens a headless engine on it, WITH
 *      the provider's own storage, app id and permissions, so it has its
 *      settings and may use what its manifest declares.
 *   3. The provider gets `{"type":"widget.request","widget":...,
 *      "req_id":"<broker's>","caller":"<the asking wapp>","args":...}`.
 *      `caller` is written by the host, never by the asking wapp.
 *   4. The provider answers `{"type":"widget.response","req_id":...,
 *      "result":{...}}` (or `"error":"..."`) when it can. The broker is told
 *      by the engine's outbox hook, so nothing polls: a provider woken by
 *      `http.done` answers from that event.
 *   5. The answer goes to the caller's inbox with the caller's own req_id,
 *      and its `module_handle_event` runs.
 *
 * One engine per provider serves every request in flight and is closed when
 * the last one is answered, so a provider always starts from its saved
 * settings. A request not answered within its time limit (the
 * functionality's `timeout_ms`, default [defaultTimeout]) is answered with
 * an error. Every outcome reaches the caller as a `widget.response`.
 */

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../launcher/launcher.dart' show WappManifest;
import '../models/monitored_task.dart';
import '../profile/storage_paths.dart'
    show wappDataStorageFor, wappPackageStorage;
import '../services/log_service.dart';
import '../services/preferences_service.dart';
import '../services/task_monitor_service.dart';
import 'functionality_registry.dart';
import 'hal_permissions.dart' show declaredPermissions;
import 'wapp_engine.dart';

class FunctionalityBroker {
  FunctionalityBroker._();
  static final FunctionalityBroker instance = FunctionalityBroker._();

  /// How long a provider has to answer when its functionality names no
  /// `timeout_ms`.
  static const Duration defaultTimeout = Duration(seconds: 30);

  /// The longest a functionality may ask for.
  static const Duration maxTimeout = Duration(minutes: 10);

  /// Open provider engines, by package directory. A second request for a
  /// provider that is still opening waits for the same engine.
  final Map<String, Future<_Session>> _sessions = {};
  int _nextId = 1;

  /// Test seam: opens the provider's engine. The default loads its
  /// `app.wasm` with its storage, app id and permissions and runs
  /// `module_init`.
  @visibleForTesting
  Future<WappEngine> Function(WappManifest provider) openEngine = _openEngine;

  /// Answers owed to the host itself, by the caller id [ask] made up.
  final Map<String, Completer<Map<String, dynamic>>> _hostCallers = {};

  /// The host's own screens asking for [functionalityId] (the chat composer
  /// asking for a link card). Same provider choice, time limit and logging
  /// as a wapp's request; the answer is the provider's `result`, and every
  /// failure (no provider, no answer in time, the provider's own error) is
  /// a [FunctionalityError].
  Future<Map<String, dynamic>> ask(
    String functionalityId,
    Map<String, dynamic> args, {
    String caller = 'host',
  }) {
    final callerId = 'host:${_nextId++}';
    final done = Completer<Map<String, dynamic>>();
    _hostCallers[callerId] = done;
    unawaited(handleRequest(
      callerEngineId: callerId,
      functionalityId: functionalityId,
      reqId: callerId,
      args: args,
      callerWapp: caller,
    ));
    return done.future;
  }

  /// A caller wapp asked for [functionalityId]. [callerWapp] is the asking
  /// wapp's folder name, as the host knows it.
  Future<void> handleRequest({
    required String callerEngineId,
    required String functionalityId,
    required String reqId,
    required Map<String, dynamic> args,
    String callerWapp = '',
  }) async {
    if (functionalityId.isEmpty || reqId.isEmpty) {
      _deliver(
        callerEngineId,
        reqId,
        error: 'widget.request missing widget/req_id',
      );
      return;
    }
    final registry = FunctionalityRegistry.instance;
    final provider = await _resolveProvider(
      functionalityId,
      registry.providersFor(functionalityId),
    );
    if (provider == null) {
      _deliver(
        callerEngineId,
        reqId,
        error: 'no provider registered for "$functionalityId"',
      );
      return;
    }

    final _Session session;
    try {
      session = await (_sessions[provider.dirPath] ??= _open(provider));
    } catch (e) {
      _sessions.remove(provider.dirPath);
      _deliver(
        callerEngineId,
        reqId,
        error: 'provider "${provider.id}" did not start: $e',
      );
      return;
    }

    final id = 'b${_nextId++}';
    final taskId = 'broker.$id';
    final monitor = TaskMonitorService.instance;
    monitor.register(
      MonitoredTask(
        id: taskId,
        name: 'provider ${provider.id}',
        description: '$functionalityId for $callerWapp',
        serviceName: 'broker',
        priority: TaskPriority.low,
        type: TaskType.oneshot,
      ),
    );
    monitor.reportStart(taskId);

    final limit = _timeoutFor(registry.defFor(functionalityId));
    session.pending[id] = _Pending(
      callerEngineId: callerEngineId,
      reqId: reqId,
      taskId: taskId,
      what: '$functionalityId for $callerWapp',
      timer: Timer(limit, () {
        _finish(
          session,
          id,
          error:
              'provider "${provider.id}" did not answer '
              '"$functionalityId" in ${limit.inSeconds}s',
        );
      }),
    );

    try {
      session.engine.sendMessage(
        jsonEncode({
          'type': 'widget.request',
          'widget': functionalityId,
          'req_id': id,
          'caller': callerWapp,
          'args': args,
        }),
      );
      session.engine.handleEvent();
    } catch (e) {
      _finish(session, id, error: 'provider "${provider.id}" threw: $e');
      return;
    }
    _drain(session);
  }

  // ── Provider sessions ───────────────────────────────────────────────

  Future<_Session> _open(WappManifest provider) async {
    final engine = await openEngine(provider);
    final session = _Session(provider, engine);
    // The provider wrote to its outbox outside our own call (it was woken by
    // an event, e.g. its HTTP answer). Read it after that call returns: an
    // answer may close the engine, which must not happen inside its own code.
    engine.onOutbox = () {
      if (session.drainScheduled) return;
      session.drainScheduled = true;
      scheduleMicrotask(() {
        session.drainScheduled = false;
        _drain(session);
      });
    };
    return session;
  }

  static Future<WappEngine> _openEngine(WappManifest provider) async {
    final pkg = wappPackageStorage(provider.dirPath);
    final wasm = await pkg.readBytes('app.wasm');
    if (wasm == null) throw StateError('no app.wasm');
    final prefs = await PreferencesService.instance();
    final engine = WappEngine(headless: true);
    try {
      // As a background wapp is set up (BackgroundWappManager.start): its own
      // data, its id, and its declared permissions, all before load, because
      // imports are bound during instantiation.
      engine.setStorage(wappDataStorageFor(prefs, provider.name));
      engine.setAppId(provider.name);
      engine.grantedPermissions = declaredPermissions(
        await pkg.readString('manifest.json'),
      );
      await engine.load(wasm);
      engine.init();
    } catch (_) {
      engine.dispose();
      rethrow;
    }
    return engine;
  }

  void _drain(_Session session) {
    if (session.closed) return;
    final engine = session.engine;
    if (engine.logs.isNotEmpty) {
      for (final l in engine.logs) {
        LogService.instance.add('[${session.provider.name}] ${l.message}');
      }
      engine.logs.clear();
    }
    for (final raw in engine.drainOutbox()) {
      // Anything but an answer (ui.*, toasts) has no screen to go to.
      if (!raw.contains('widget.response')) continue;
      try {
        final msg = jsonDecode(raw);
        if (msg is! Map<String, dynamic>) continue;
        if (msg['type'] != 'widget.response') continue;
        final id = msg['req_id'];
        if (id is! String) continue;
        final result = msg['result'];
        final error = msg['error'];
        _finish(
          session,
          id,
          result: result is Map<String, dynamic> ? result : null,
          error: error is String ? error : null,
        );
      } catch (_) {}
    }
  }

  /// Answer request [id] (once) and close the provider when it was the last.
  void _finish(
    _Session session,
    String id, {
    Map<String, dynamic>? result,
    String? error,
  }) {
    final p = session.pending.remove(id);
    if (p == null) return; // already answered, or timed out
    p.timer.cancel();
    final monitor = TaskMonitorService.instance;
    if (error == null) {
      monitor.reportSuccess(p.taskId);
    } else {
      monitor.reportFailure(p.taskId, error);
    }
    monitor.unregister(p.taskId);
    // A page engine's own log never reaches /api/log, so the exchange is
    // recorded here: who asked for what, who answered, how long it took.
    LogService.instance.add(
      'broker: ${p.what} ${error == null ? 'answered' : 'failed'} by '
      '${session.provider.name} in ${p.since.elapsedMilliseconds}ms'
      '${error == null ? '' : ' ($error)'}',
    );
    _deliver(
      p.callerEngineId,
      p.reqId,
      result: result,
      error: error,
      provider: session.provider.id,
    );
    if (session.pending.isEmpty) _close(session);
  }

  void _close(_Session session) {
    if (session.closed) return;
    session.closed = true;
    _sessions.remove(session.provider.dirPath);
    session.engine.onOutbox = null;
    // Not inside the provider's own call (see _open).
    scheduleMicrotask(session.engine.dispose);
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  static Duration _timeoutFor(FunctionalityDef? def) {
    final ms = def?.timeoutMs ?? 0;
    if (ms <= 0) return defaultTimeout;
    final d = Duration(milliseconds: ms);
    return d > maxTimeout ? maxTimeout : d;
  }

  Future<WappManifest?> _resolveProvider(
    String functionalityId,
    List<WappManifest> all,
  ) async {
    // The core's own entries have no package to run.
    final providers = [
      for (final p in all)
        if (p.dirPath.isNotEmpty) p,
    ];
    if (providers.isEmpty) return null;
    if (providers.length == 1) return providers.first;
    final prefs = await PreferencesService.instance();
    final preferredId = prefs.getPreferredProvider(functionalityId);
    if (preferredId != null) {
      for (final p in providers) {
        if (p.id == preferredId) return p;
      }
    }
    return providers.first;
  }

  void _deliver(
    String callerEngineId,
    String reqId, {
    Map<String, dynamic>? result,
    String? error,
    String? provider,
  }) {
    final host = _hostCallers.remove(callerEngineId);
    if (host != null) {
      if (error != null || result == null) {
        host.completeError(FunctionalityError(error ?? 'no result'));
      } else {
        host.complete(result);
      }
      return;
    }
    final engine = WappEngine.lookup(callerEngineId);
    if (engine == null) return; // the caller was closed meanwhile
    engine.sendMessage(
      jsonEncode({
        'type': 'widget.response',
        'req_id': reqId,
        if (provider != null) 'widget_provider': provider,
        if (error != null)
          'error': error
        else if (result != null)
          'result': result,
      }),
    );
    engine.handleEvent();
  }
}

class _Session {
  final WappManifest provider;
  final WappEngine engine;
  final Map<String, _Pending> pending = {};
  bool drainScheduled = false;
  bool closed = false;
  _Session(this.provider, this.engine);
}

class _Pending {
  final String callerEngineId;
  final String reqId;
  final String taskId;
  final Timer timer;

  /// "<functionality> for <caller>", for the log line when it is answered.
  final String what;
  final Stopwatch since = Stopwatch()..start();
  _Pending({
    required this.callerEngineId,
    required this.reqId,
    required this.taskId,
    required this.timer,
    required this.what,
  });
}

/// Why a functionality the host asked for ([FunctionalityBroker.ask]) gave
/// no result: the words the broker or the provider gave.
class FunctionalityError implements Exception {
  const FunctionalityError(this.message);
  final String message;
  @override
  String toString() => message;
}
