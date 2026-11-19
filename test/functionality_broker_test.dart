/*
 * The broker between wapps: a provider that answers later (after its own
 * network request), one that never answers, several requests in flight, and
 * who the provider is told is asking.
 *
 * No wasm: the provider is an engine the test opens, read and answered by
 * hand through the engine's test seams. What is under test is the broker's
 * contract with both sides.
 */

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/launcher/launcher.dart' show WappManifest;
import 'package:xprs/wapp/functionality_broker.dart';
import 'package:xprs/wapp/functionality_registry.dart';
import 'package:xprs/wapp/wapp_engine.dart';

void main() {
  final broker = FunctionalityBroker.instance;
  late WappEngine provider;
  late WappEngine caller;
  var opened = 0;

  Map<String, dynamic> last(WappEngine e) =>
      jsonDecode(e.debugInbox.last) as Map<String, dynamic>;

  setUp(() {
    opened = 0;
    caller = WappEngine(headless: true);
    FunctionalityRegistry.instance.clear();
    FunctionalityRegistry.instance.register(
      WappManifest.fromJson({
        'id': 'tools.test.provider',
        'title': 'Provider',
        'provides': {
          'functionalities': [
            {'id': 'slow.answer', 'description': '', 'timeout_ms': 90000},
            'quick.answer',
          ],
        },
      }, '/nowhere/provider'),
    );
    broker.openEngine = (_) async {
      opened++;
      return provider = WappEngine(headless: true);
    };
  });

  tearDown(() => caller.dispose());

  Future<void> ask(String id, String reqId, {String what = 'slow.answer'}) =>
      broker.handleRequest(
        callerEngineId: caller.engineId,
        callerWapp: 'asker',
        functionalityId: what,
        reqId: reqId,
        args: {'q': id},
      );

  test('an answer that comes later reaches the caller', () {
    fakeAsync((async) {
      ask('one', 'r1');
      async.flushMicrotasks();
      final req = last(provider);
      expect(req['type'], 'widget.request');
      expect(req['widget'], 'slow.answer');
      expect(req['caller'], 'asker', reason: 'named by the host');
      expect(req['args'], {'q': 'one'});
      expect(caller.debugInbox, isEmpty, reason: 'nothing yet');

      // Twenty seconds later the provider's own request is answered and it
      // writes its response, outside any call of the broker's.
      async.elapse(const Duration(seconds: 20));
      provider.debugEmit(
        jsonEncode({
          'type': 'widget.response',
          'req_id': req['req_id'],
          'result': {'text': 'hello'},
        }),
      );
      async.flushMicrotasks();
      final res = last(caller);
      expect(res['type'], 'widget.response');
      expect(res['req_id'], 'r1', reason: "the caller's own id");
      expect(res['result'], {'text': 'hello'});
      expect(res['widget_provider'], 'tools.test.provider');
    });
  });

  test('a provider that never answers is an error after its time limit', () {
    fakeAsync((async) {
      ask('one', 'r1');
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 89));
      expect(caller.debugInbox, isEmpty, reason: 'its own 90 s, not 30');
      async.elapse(const Duration(seconds: 2));
      expect(last(caller)['error'], contains('did not answer'));
      expect(last(caller)['req_id'], 'r1');

      // Without a timeout_ms: the default.
      ask('two', 'r2', what: 'quick.answer');
      async.flushMicrotasks();
      async.elapse(FunctionalityBroker.defaultTimeout);
      expect(last(caller)['req_id'], 'r2');
      expect(last(caller)['error'], isNotNull);
    });
  });

  test(
    'requests in flight share one provider and keep their answers apart',
    () {
      fakeAsync((async) {
        ask('one', 'same');
        async.flushMicrotasks();
        final first = last(provider)['req_id'];
        ask('two', 'other');
        async.flushMicrotasks();
        final second = last(provider)['req_id'];
        expect(opened, 1);
        expect(second, isNot(first));

        provider.debugEmit(
          jsonEncode({
            'type': 'widget.response',
            'req_id': second,
            'result': {'text': 'two'},
          }),
        );
        async.flushMicrotasks();
        expect(last(caller)['req_id'], 'other');
        expect(last(caller)['result'], {'text': 'two'});

        provider.debugEmit(
          jsonEncode({
            'type': 'widget.response',
            'req_id': first,
            'error': 'no key',
          }),
        );
        async.flushMicrotasks();
        expect(last(caller)['req_id'], 'same');
        expect(last(caller)['error'], 'no key');

        // The last answer closed the provider: the next request opens it anew,
        // so it starts from its saved settings.
        ask('three', 'r3');
        async.flushMicrotasks();
        expect(opened, 2);
        async.elapse(const Duration(seconds: 91));
      });
    },
  );

  test('no provider, and a provider that does not start', () {
    fakeAsync((async) {
      ask('one', 'r1', what: 'nobody.has.this');
      async.flushMicrotasks();
      expect(last(caller)['error'], contains('no provider'));

      broker.openEngine = (_) async => throw StateError('no app.wasm');
      ask('two', 'r2');
      async.flushMicrotasks();
      expect(last(caller)['req_id'], 'r2');
      expect(last(caller)['error'], contains('did not start'));
    });
  });
}
