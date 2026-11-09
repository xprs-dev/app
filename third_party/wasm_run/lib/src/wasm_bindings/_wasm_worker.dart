// PATCHED (xprs): ported from dart:html / dart:js_util to dart:js_interop so
// it compiles under dart2wasm as well as dart2js. Messages from the worker
// are read with [dartifyJson] (a BigInt stays a JS BigInt, i.e. an [I64]).
// See README.xprs.md.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:wasm_run/src/wasm_bindings/_atomics_web.dart';
import 'package:wasm_run/src/wasm_bindings/wasm_interface.dart';
import 'package:wasm_run/src/web/js_helpers.dart';

/// A task that can be run in a [WasmWorker].
class WorkerTask {
  /// The name of the wasm function to call.
  final String functionName;

  /// The arguments to pass to the function.
  final List<Object?> args;

  /// The completer that will be completed when the task is done.
  final Completer<List<Object?>> completer = Completer();

  /// A task that can be run in a [WasmWorker].
  WorkerTask(this.functionName, this.args);

  @override
  String toString() {
    return 'WorkerTask(functionName: $functionName, args: $args,'
        ' completer: ${completer.isCompleted})';
  }
}

void postMessageToWorker(JSObject worker, JSAny data) {
  worker.callMethod<JSAny?>('postMessage'.toJS, data);
}

JSObject _construct(String constructor, JSAny arg) =>
    (globalContext[constructor]! as JSFunction).callAsConstructor(arg);

/// A wrapper around a JS `Worker` that can be used to run WASM code in a
/// separate Web Worker.
class WasmWorker {
  /// The id of the worker.
  final int workerId;

  /// The underlying JS `Worker`.
  final JSObject worker;

  final List<WasmFunction> _functions;
  final ByteData _byteData;

  late final JSFunction _onMessage;
  final Completer<WasmWorker> _onLoaded = Completer();

  final WorkersConfig _workersConfig;

  /// The tasks that are currently running.
  final Map<int, WorkerTask> _tasks = {};
  int _lastTaskId = 0;

  WasmWorker._(
    this.workerId,
    this.worker,
    this._workersConfig,
    this._functions,
    this._byteData,
  ) {
    _onMessage = ((JSObject event) => _handleMessage(event['data'])).toJS;
    worker.callMethod<JSAny?>(
      'addEventListener'.toJS,
      'message'.toJS,
      _onMessage,
    );
  }

  /// A wrapper around a JS `Worker` that can be used to run WASM code in a
  /// separate Web Worker.
  ///
  /// Creates and instantiates a new [WasmWorker] with the given [workerId]
  static Future<WasmWorker> create({
    required int workerId,
    required WorkersConfig workersConfig,
    required JSObject wasmImports,
    required JSObject wasmModule,
    required List<WasmFunction> functions,
  }) {
    if (!globalContext.has('Worker')) {
      throw UnsupportedError('Web Workers are not supported');
    }
    final sharedBuffer = _construct('SharedArrayBuffer', 256.toJS);
    final byteData =
        (_construct('DataView', sharedBuffer) as JSDataView).toDart;
    final worker = _construct('Worker', workersConfig.workerScriptUrl.toJS);

    final wasmWorker =
        WasmWorker._(workerId, worker, workersConfig, functions, byteData);
    worker.callMethod<JSAny?>(
      'addEventListener'.toJS,
      'error'.toJS,
      ((JSAny? error) {
        if (!wasmWorker._onLoaded.isCompleted) {
          wasmWorker._onLoaded.completeError(error ?? 'Worker error');
        }
      }).toJS,
    );

    final message = JSObject()
      ..['cmd'] = 'load'.toJS
      ..['wasmImports'] = wasmImports
      ..['wasmModule'] = wasmModule
      ..['workerId'] = workerId.toJS
      ..['sharedBuffer'] = sharedBuffer
      ..['workerMapImportsScriptUrl'] =
          workersConfig.workerMapImportsScriptUrl?.toJS;
    postMessageToWorker(worker, message);
    return wasmWorker._onLoaded.future;
  }

  /// Runs the given [task] in the worker.
  Future<List<Object?>> run(WorkerTask task) {
    _tasks[++_lastTaskId] = task;
    // jsifyMixed passes an i64 (a JS BigInt) through as it is.
    final data = JSObject()
      ..['cmd'] = 'run'.toJS
      ..['args'] = jsifyMixed(task.args)
      ..['functionExport'] = task.functionName.toJS
      ..['taskId'] = _lastTaskId.toJS;

    postMessageToWorker(worker, data);
    return task.completer.future;
  }

  /// Terminates the worker.
  void dispose() {
    worker.callMethod<JSAny?>(
      'removeEventListener'.toJS,
      'message'.toJS,
      _onMessage,
    );
    worker.callMethod<JSAny?>('terminate'.toJS);
  }

  @override
  String toString() {
    return 'WasmWorker(workerId: $workerId, worker: $worker,'
        ' _onLoaded: ${_onLoaded.isCompleted}, _tasks: $_tasks,'
        ' _lastTaskId: $_lastTaskId)';
  }

  void _handleMessage(JSAny? eventData) {
    final decoded = dartifyJson(eventData);
    if (decoded is String) {
      print(decoded);
      return;
    }
    final data_ = (decoded! as Map).cast<String, Object?>();
    switch (data_['cmd']) {
      case 'loaded':
        _onLoaded.complete(this);
        break;
      case 'call':
        final functionId = data_['functionId']! as int;
        final function = _functions[functionId];
        final args = data_['args']! as List;
        final results = function(args);
        final bytes = _byteData;

        int offset = 4;
        int i = 0;
        for (final type in function.results!) {
          final value = results[i++]!;
          switch (type) {
            case ValueTy.i32:
              bytes.setInt32(offset += 4, value as int, Endian.little);
              break;
            case ValueTy.f32:
              bytes.setFloat32(offset += 4, value as double, Endian.little);
              break;
            case ValueTy.i64:
              i64.setInt64(bytes, offset += 8, value, Endian.little);
              break;
            case ValueTy.f64:
              bytes.setFloat64(offset += 8, value as double, Endian.little);
              break;
            case ValueTy.v128:
            case ValueTy.externRef:
            case ValueTy.funcRef:
              // TODO: implement refs
              throw UnimplementedError();
          }
        }
        atomics.notify(Int32List.sublistView(bytes), 0, 1);
        break;
      case 'event':
        _workersConfig.onWorkerMessage?.call(data_['data']);
        break;
      case 'result':
        final data = _PostMessageResult.fromJson(data_);
        final taskId = data.taskId;
        final List<Object?> result;
        if (data.isUndefined) {
          result = [];
        } else if (data.result is List) {
          result = (data.result! as List).cast();
        } else {
          result = [data.result];
        }
        _tasks.remove(taskId)!.completer.complete(result);
        break;
      case 'alert':
        final data = _PostMessageAlert.fromJson(data_);
        final taskId = data.taskId;
        if (taskId != null) {
          _tasks.remove(taskId)!.completer.completeError(data);
        } else if (!_onLoaded.isCompleted) {
          _onLoaded.completeError(data);
        } else {
          print(data);
        }
        break;
      default:
        print('Unknown worker message: $data_');
    }
  }
}

class _PostMessageResult {
  final String cmd;
  final int workerId;
  final int taskId;
  final Object? result;
  final bool isUndefined;

  _PostMessageResult({
    required this.cmd,
    required this.workerId,
    required this.taskId,
    required this.result,
    required this.isUndefined,
  });

  factory _PostMessageResult.fromJson(Map<String, Object?> json) {
    return _PostMessageResult(
      cmd: json['cmd']! as String,
      workerId: json['workerId']! as int,
      taskId: json['taskId']! as int,
      result: json['result'],
      isUndefined: json['isUndefined'] as bool? ?? false,
    );
  }
}

class _PostMessageAlert {
  final String cmd;
  final int? workerId;
  final int? taskId;
  final String? text;
  final bool didThrow;

  _PostMessageAlert({
    required this.cmd,
    required this.workerId,
    required this.taskId,
    required this.text,
    required this.didThrow,
  });

  factory _PostMessageAlert.fromJson(Map<String, Object?> json) {
    return _PostMessageAlert(
      cmd: json['cmd']! as String,
      workerId: json['workerId'] as int?,
      taskId: json['taskId'] as int?,
      text: json['text'] as String?,
      didThrow: json['didThrow'] as bool? ?? false,
    );
  }

  @override
  String toString() {
    return 'PostMessageAlert(cmd: $cmd, workerId: $workerId, taskId: $taskId,'
        ' text: $text, didThrow: $didThrow)';
  }
}
