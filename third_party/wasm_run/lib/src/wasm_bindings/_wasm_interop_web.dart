// PATCHED (xprs): ported from dart:js_util + package:wasm_interop (both
// package:js based, which dart2wasm cannot compile) to dart:js_interop, over
// the bindings in _wasm_js_web.dart. The public behaviour is upstream's; what
// changed is that every value crossing the JS boundary is converted by its
// wasm type ([_toJs] / [_toDart]) instead of relying on dart2js's "a Dart
// value is a JS value". See README.xprs.md.
import 'dart:collection' show Queue, UnmodifiableMapView;
import 'dart:convert' show utf8;
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data' show Uint8List;

import 'package:wasm_run/src/ffi.dart' show WasmRunLibrary;
import 'package:wasm_run/src/logger.dart';
import 'package:wasm_run/src/wasm_bindings/_atomics_web.dart';
import 'package:wasm_run/src/wasm_bindings/_wasi_web.dart';
import 'package:wasm_run/src/wasm_bindings/_wasm_feature_detect_web.dart';
import 'package:wasm_run/src/wasm_bindings/_wasm_js_web.dart';
import 'package:wasm_run/src/wasm_bindings/_wasm_worker.dart';
import 'package:wasm_run/src/wasm_bindings/wasm.dart';
import 'package:wasm_run/src/web/js_helpers.dart';

bool isVoidReturn(dynamic value) {
  switch (value) {
    case null:
      return false;
    default:
      return value == null;
  }
}

Future<WasmRuntimeFeatures> _calculateFeatures() async {
  final wfd = wasmFeatureDetect;
  final features = await Future.wait([
    featureToFuture(wfd.bigInt()), // 0 TODO: left
    featureToFuture(wfd.bulkMemory()), // 1
    featureToFuture(wfd.exceptions()), // 2
    featureToFuture(wfd.extendedConst()), // 3
    featureToFuture(wfd.gc()), // 4
    // TODO:  featureToFuture(wfd.jspi()), // 5 left
    Future.value(false),
    featureToFuture(wfd.memory64()), // 6
    featureToFuture(wfd.multiValue()), // 7
    featureToFuture(wfd.mutableGlobals()), // 8
    featureToFuture(wfd.referenceTypes()), // 9
    featureToFuture(wfd.relaxedSimd()), // 10
    featureToFuture(wfd.saturatedFloatToInt()), // 11
    featureToFuture(wfd.signExtensions()), // 12
    featureToFuture(wfd.simd()), // 13
    featureToFuture(wfd.streamingCompilation()), // 14
    featureToFuture(wfd.tailCall()), // 15
    featureToFuture(wfd.threads()), // 16
  ]);

  bool typeReflection;
  try {
    final type =
        _getGlobalType(JsWasmGlobal('i32', 0.toJS, mutable: true));
    final hasFunctionProperty =
        (globalContext['WebAssembly']! as JSObject).has('Function');
    typeReflection = (type?.mutable ?? false) &&
        type?.value == ValueTy.i32 &&
        hasFunctionProperty;
  } catch (_) {
    typeReflection = false;
  }
  final wasmFeatures = WasmFeatures(
    mutableGlobal: features[8],
    saturatingFloatToInt: features[11],
    signExtension: features[12],
    referenceTypes: features[9],
    multiValue: features[7],
    bulkMemory: features[1],
    floats: true,
    threads: features[16],
    exceptions: features[2], // not in firefox
    simd: features[13], //  not in safari

    relaxedSimd: features[10],
    tailCall: features[15],
    multiMemory: false, // TODO(web-compat): check
    memory64: features[6],
    extendedConst: features[3],
    componentModel: false, // TODO(web-compat): check
    memoryControl: false, // TODO(web-compat): check
    garbageCollection: features[4],
    typeReflection: typeReflection,
    wasiFeatures: const WasmWasiFeatures(
      io: true,
      filesystem: true,
      clocks: true,
      random: true,
      poll: false,
      machineLearning: false,
      crypto: false,
      threads: false,
    ),
    // TODO: moduleLinking
  );

  return WasmRuntimeFeatures(
    name: 'browser',
    version: WasmRunLibrary.version,
    isBrowser: true,
    supportedFeatures: wasmFeatures,
    defaultFeatures: wasmFeatures,
  );
}

Future<WasmRuntimeFeatures>? _features;
Future<WasmRuntimeFeatures> wasmRuntimeFeatures() {
  return _features ??= _calculateFeatures();
}

Future<WasmModule> compileWasmModule(
  Uint8List bytes, {
  ModuleConfig? config,
}) async {
  return _WasmModule.compileAsync(bytes);
}

WasmModule compileWasmModuleSync(
  Uint8List bytes, {
  ModuleConfig? config,
}) {
  return _WasmModule(bytes);
}

/// The shim's `{ name: File | Directory }` object for a WASI directory tree.
JSObject _mapWasiFiles(Map<String, WasiFd> items) {
  final object = newJsObject();
  items.forEach((key, value) {
    if (value is WasiFile) {
      object[key] = WasiWebFile(value.content);
    } else {
      object[key] =
          WasiWebDirectory(_mapWasiFiles((value as WasiDirectory).items));
    }
  });
  return object;
}

class _WASI {
  final WASI inner;
  final WasiStdio? stdout;
  final WasiStdio? stderr;

  _WASI(this.inner, this.stdout, this.stderr);
}

WasmExternalKind _kind(String jsKind) => WasmExternalKind.values.byName(jsKind);

class _WasmModule extends WasmModule {
  final JsWasmModule module;
  _WasmModule(Uint8List bytes) : module = JsWasmModule(bytes.toJS);
  _WasmModule._(this.module);

  static Future<WasmModule> compileAsync(Uint8List bytes) async {
    final module = await wasmCompile(bytes.toJS).toDart;
    return _WasmModule._(module);
  }

  @override
  WasmSharedMemory createSharedMemory({
    required int minPages,
    required int maxPages,
  }) {
    return _SharedMemory(
      JsWasmMemory(initial: minPages, maximum: maxPages, shared: true),
      MemoryTy(minimum: minPages, maximum: maxPages, shared: true),
    );
  }

  @override
  WasmInstanceBuilder builder({
    WasiConfig? wasiConfig,
    WorkersConfig? workersConfig,
  }) {
    _WASI? wasi;
    if (wasiConfig != null) {
      final stdout = wasiConfig.captureStdout ? WasiStdio() : null;
      final stderr = wasiConfig.captureStderr ? WasiStdio() : null;

      final wasiWeb = WASI(
        [for (final a in wasiConfig.args) a.toJS].toJS,
        [for (final e in wasiConfig.env) '${e.name}=${e.value}'.toJS].toJS,
        <Fd>[
          OpenFile(WasiWebFile(Uint8List(0))), // TODO: stdin
          stdout?.fd ?? OpenFile(WasiWebFile(Uint8List(0))),
          stderr?.fd ?? OpenFile(WasiWebFile(Uint8List(0))),
          ...wasiConfig.webBrowserFileSystem.entries.map(
            (e) => PreopenDirectory(e.key, _mapWasiFiles(e.value.items)),
          ),
        ].toJS,
      );
      wasi = _WASI(wasiWeb, stdout, stderr);
    }

    return _Builder(this, wasi, workersConfig);
  }

  @override
  List<WasmModuleImport> getImports() {
    return JsWasmModule.imports(module)
        .toDart
        .map(
          (e) => WasmModuleImport(
            e.module,
            e.name,
            _kind(e.kind),
            type: _getExternalType(e),
          ),
        )
        .toList(growable: false);
  }

  @override
  List<WasmModuleExport> getExports() {
    return JsWasmModule.exports(module)
        .toDart
        .map(
          (e) => WasmModuleExport(
            e.name,
            _kind(e.kind),
            type: _getExternalType(e),
          ),
        )
        .toList(growable: false);
  }
}

class _Builder extends WasmInstanceBuilder {
  @override
  final _WasmModule module;
  JsWasmModule get _module => module.module;
  final _WASI? wasi;
  final WorkersConfig? workersConfig;
  final Map<String, Map<String, WasmExternal>> importMap = {};

  _Builder(this.module, this.wasi, this.workersConfig);

  @override
  WasmMemory createMemory({required int minPages, int? maxPages}) {
    return _Memory(
      JsWasmMemory(initial: minPages, maximum: maxPages),
      MemoryTy(minimum: minPages, maximum: maxPages, shared: false),
    );
  }

  @override
  WasmTable createTable({
    required WasmValue value,
    required int minSize,
    int? maxSize,
  }) {
    return _Table(
      JsWasmTable(
        element: value.type == ValueTy.funcRef ? 'anyfunc' : 'externref',
        initial: minSize,
        maximum: maxSize,
        value: _toJs(value.value, value.type),
      ),
      TableTy(
        element: value.type,
        minimum: minSize,
        maximum: maxSize,
      ),
      value,
    );
  }

  @override
  WasmGlobal createGlobal(WasmValue value, {required bool mutable}) {
    final type = GlobalTy(value: value.type, mutable: mutable);

    final val = value.value;
    final JsWasmGlobal inner;
    switch (value.type) {
      case ValueTy.i32:
        inner = JsWasmGlobal('i32', (val! as int).toJS, mutable: mutable);
        break;
      case ValueTy.i64:
        inner = JsWasmGlobal('i64', _toJs(val!, ValueTy.i64), mutable: mutable);
        break;
      case ValueTy.f32:
        inner = JsWasmGlobal('f32', (val! as num).toDouble().toJS,
            mutable: mutable);
        break;
      case ValueTy.f64:
        inner = JsWasmGlobal('f64', (val! as num).toDouble().toJS,
            mutable: mutable);
        break;
      case ValueTy.v128:
        throw UnsupportedError('v128 external values are not supported on web');
      case ValueTy.externRef:
        inner = JsWasmGlobal('externref', _toJs(val, ValueTy.externRef),
            mutable: mutable);
        break;
      case ValueTy.funcRef:
        // TODO(web): Implement funcRef "anyfunc"
        inner = JsWasmGlobal('externref', _toJs(val, ValueTy.externRef),
            mutable: mutable);
        break;
    }
    return _Global(inner, type, value);
  }

  @override
  WasmInstanceBuilder addImport(
    String moduleName,
    String name,
    WasmExternal value,
  ) {
    importMap.putIfAbsent(moduleName, () => {})[name] = value;
    return this;
  }

  @override
  WasmInstanceFuel? fuel() => null;

  @override
  WasmInstance buildSync() {
    if (workersConfig != null) {
      throw Exception('numThreads is not supported in buildSync()');
    }
    final instance = JsWasmInstance(_module, _mapImports());
    return _Instance(this, instance, null);
  }

  @override
  Future<WasmInstance> build() async {
    final instance = await wasmInstantiateModule(_module, _mapImports()).toDart;

    List<WasmWorker>? workers;
    if (workersConfig != null) {
      workers = await _createWorkers();
    }
    return _Instance(this, instance, workers);
  }

  /// The WASI imports under `wasi_snapshot_preview1`, with any import the
  /// caller added for that module taking precedence (as upstream).
  void _addWasiImports(JSObject imports) {
    if (wasi == null) return;
    const name = 'wasi_snapshot_preview1';
    imports[name] =
        objectAssign(newJsObject(), wasi!.inner.wasiImport, imports[name]);
  }

  JSObject _mapImports() {
    final imports = newJsObject();
    importMap.forEach((moduleName, values) {
      final moduleObject = newJsObject();
      values.forEach((name, value) {
        moduleObject[name] = value.when<JSAny>(
          memory: (memory) => (memory as _Memory).memory,
          table: (table) => (table as _Table).table,
          global: (global) => (global as _Global).global,
          function: _jsFunctionOf,
        );
      });
      imports[moduleName] = moduleObject;
    });
    _addWasiImports(imports);
    return imports;
  }

  Future<List<WasmWorker>> _createWorkers() async {
    final List<WasmFunction> functions = [];
    final mappedImports = importMap.map(
      (key, value) => MapEntry(
        key,
        value.map((key, value) {
          final mapped = value.when<Object?>(
            memory: (memory) => memory is _SharedMemory
                ? memory.memory
                : typeToJson(ExternalType.memory(memory.type!)),
            table: (table) {
              final map = typeToJson(ExternalType.table(table.type!));
              if (table is _Table && table._initialValue?.value != null) {
                map['initialValue'] = _toJs(
                  table._initialValue!.value,
                  table._initialValue.type,
                );
              }
              return map;
            },
            global: (global) {
              final map = typeToJson(ExternalType.global(global.type!));
              if (global is _Global && global._initialValue?.value != null) {
                map['initialValue'] = _toJs(
                  global._initialValue!.value,
                  global._initialValue.type,
                );
              }
              return map;
            },
            // functions can't be passed to workers. One should use scripts
            function: (function) {
              if (workersConfig!.workerMapImportsScriptUrl != null) {
                return null;
              }
              functions.add(function);
              return {
                'functionId': functions.length - 1,
                'resultTypes': function.results!.map((e) {
                  const supportedTypes = [
                    ValueTy.i32,
                    ValueTy.i64,
                    ValueTy.f32,
                    ValueTy.f64,
                  ];
                  if (!supportedTypes.contains(e)) {
                    throw Exception(
                      'Result type $e not supported for imported functions'
                      ' in workers. SupportedTypes: $supportedTypes',
                    );
                  }
                  return e.name;
                }).toList(),
              };
            },
          );
          return MapEntry(key, mapped);
        }),
      ),
    );
    final imports = jsifyMixed(mappedImports)! as JSObject;
    // TODO: implement wasi in workers
    _addWasiImports(imports);

    final workers = await Future.wait(
      Iterable.generate(
        workersConfig!.numberOfWorkers,
        (index) {
          return WasmWorker.create(
            workerId: index + 1,
            workersConfig: workersConfig!,
            wasmModule: _module,
            wasmImports: imports,
            functions: functions,
          );
        },
      ),
    );

    return workers;
  }
}

class _Instance extends WasmInstance {
  final _Builder builder;
  final JsWasmInstance instance;
  @override
  final _WasmModule module;
  @override
  late final UnmodifiableMapView<String, WasmExternal> exports;

  final List<WasmWorker>? workers;
  final List<WasmWorker> availableWorkers;
  final Queue<WorkerTask> tasks = Queue();

  _Instance(this.builder, this.instance, this.workers)
      : module = builder.module,
        availableWorkers = workers ?? [] {
    // Grouped as upstream (wasm_interop): functions, globals, memories,
    // tables, each in export order.
    final functions = <String, WasmExternal>{};
    final globals = <String, WasmExternal>{};
    final memories = <String, WasmExternal>{};
    final tables = <String, WasmExternal>{};
    final exportsObject = instance.exports;
    for (final jsKey in objectKeys(exportsObject).toDart) {
      final key = jsKey.toDart;
      final value = exportsObject[key];
      if (value == null) continue;
      if (value.typeofEquals('function')) {
        functions[key] = _makeWasmFunction(value as JSFunction, key);
      } else if (value.instanceOfString('WebAssembly.Global')) {
        globals[key] = _Global(value as JsWasmGlobal, null, null);
      } else if (value.instanceOfString('WebAssembly.Memory')) {
        final memory = value as JsWasmMemory;
        final ctor = (memory.buffer as JSObject)['constructor'] as JSObject?;
        if (ctor?['name'].dartify() == 'SharedArrayBuffer') {
          memories[key] = _SharedMemory(memory, null);
        } else {
          memories[key] = _Memory(memory, null);
        }
      } else if (value.instanceOfString('WebAssembly.Table')) {
        tables[key] = _Table(value as JsWasmTable, null, null);
      }
    }
    exports = UnmodifiableMapView({
      ...functions,
      ...globals,
      ...memories,
      ...tables,
    });
    final wasi = builder.wasi?.inner;
    if (wasi != null) {
      if (getFunction('_start')?.params.isEmpty ?? false) {
        wasi.start(instance);
      } else if (getFunction('_initialize')?.params.isEmpty ?? false) {
        wasi.initialize(instance);
      } else {
        wasi['inst'] = instance;
        logWasiNoStartOrInitialize();
      }
    }
  }
  @override
  Future<List<List<Object?>>> runParallel(
    WasmFunction function,
    List<List<Object?>> argsLists,
  ) {
    if (workers == null) {
      throw Exception(
        '`runParallel` can only be called when numThreads has been configured'
        ' for WasmInstanceBuilder in `WasmModule.builder`.',
      );
    }
    final entry = exports.entries.firstWhere(
      (e) => e.value == function,
      orElse: () => throw Exception(
        '`runParallel` can only be called for exported functions.'
        ' $function not found in exports.',
      ),
    );
    final currentTasks = argsLists
        .map((args) => WorkerTask(entry.key, args))
        .toList(growable: false);
    tasks.addAll(currentTasks);
    _executeTasks();

    return Future.wait(
      currentTasks.map((e) => e.completer.future).toList(growable: false),
    );
  }

  void _executeTasks() {
    while (availableWorkers.isNotEmpty && tasks.isNotEmpty) {
      final worker = availableWorkers.removeLast();
      final task = tasks.removeFirst();

      worker.run(task).whenComplete(() {
        availableWorkers.add(worker);
        _executeTasks();
      });
    }
  }

  @override
  Future<WasiFile?> wasiOpenFile(
    String path, {
    bool create = false,
    bool truncate = false,
    // bool directory = false,
    bool exclusive = false,
  }) async {
    if (builder.wasi == null) return null;
    final directories = builder.wasi!.inner.fds
        .sublist(3)
        .map((fd) => fd as PreopenDirectory);
    final oflags = (create ? oflagsCREAT : 0) |
        (truncate ? oflagsTRUNC : 0) |
        // (directory ? oflagsDIRECTORY : 0) |
        (exclusive ? oflagsEXCL : 0);
    for (final dir in directories) {
      final dirName = utf8.decode(dir.prestat_name);
      if (!path.startsWith(dirName)) {
        continue;
      }
      final value = dir.path_open(
        0.toJS,
        path.substring(dirName.length),
        oflags.toJS,
        _toJs(i64.fromInt(0), ValueTy.i64),
        _toJs(i64.fromInt(0), ValueTy.i64),
        0.toJS,
      );
      final fdObj = value.fd_obj;
      if (fdObj != null) {
        final file = (fdObj as OpenFile).file;
        return WasiFile(file.data);
      }
    }
    // TODO: throw Exception('No preopened dir for $path');
    return null;
  }

  @override
  WasmInstanceFuel? fuel() => null;

  @override
  Stream<Uint8List> get stderr {
    final stream = builder.wasi?.stderr?.streamController.stream;
    if (stream == null) {
      throw Exception(
        'WASI stderr is not available.'
        ' You should enable it with `WasiConfig.captureStderr`.',
      );
    }
    return stream;
  }

  @override
  Stream<Uint8List> get stdout {
    final stream = builder.wasi?.stdout?.streamController.stream;
    if (stream == null) {
      throw Exception(
        'WASI stdout is not available.'
        ' You should enable it with `WasiConfig.captureStdout`.',
      );
    }
    return stream;
  }

  @override
  void dispose() {
    builder.wasi?.stderr?.streamController.close();
    builder.wasi?.stdout?.streamController.close();
    workers?.forEach((w) => w.dispose());
  }
}

// ── Values across the JS boundary ──────────────────────────────────────────

/// The JS function standing for a [WasmFunction]: the export it wraps, or a
/// JS wrapper of a host function, created once and cached so that a function
/// keeps one identity in import objects and tables.
final _jsFunctions = Expando<JSFunction>('wasm_run.jsFunction');

JSFunction _jsFunctionOf(WasmFunction f) =>
    _jsFunctions[f] ??= _importFunction(f);

/// Converts a Dart value to the JS value the WebAssembly API expects for a
/// value of wasm type [ty] (null: unknown, convert by the Dart type).
JSAny? _toJs(Object? value, ValueTy? ty) {
  if (value == null) return null;
  if (value is WasmFunction) return _jsFunctionOf(value);
  if (value is BigInt) return jsBigInt(value.toString().toJS);
  if (value is int) {
    // i64 crosses as a BigInt; through the decimal string so no bit of a
    // 64-bit dart2wasm int is lost.
    return ty == ValueTy.i64 ? jsBigInt(value.toString().toJS) : value.toJS;
  }
  if (value is double) return value.toJS;
  return jsifyMixed(value);
}

/// Converts a JS value of wasm type [ty] (null: unknown) to Dart. An i64 stays
/// a JS `BigInt` ([I64] on the web); a function becomes a [WasmFunction].
Object? _toDart(JSAny? value, ValueTy? ty) {
  if (value == null || value.isUndefinedOrNull) return null;
  switch (ty) {
    case ValueTy.i32:
      return (value as JSNumber).toDartDouble.toInt();
    case ValueTy.f32:
    case ValueTy.f64:
      return (value as JSNumber).toDartDouble;
    case ValueTy.i64:
      return value;
    case ValueTy.v128:
    case ValueTy.externRef:
    case ValueTy.funcRef:
    case null:
      break;
  }
  if (value.typeofEquals('number')) return jsNumberToDart(value as JSNumber);
  if (value.typeofEquals('string')) return (value as JSString).toDart;
  if (value.typeofEquals('boolean')) return (value as JSBoolean).toDart;
  if (value.typeofEquals('function')) {
    return _makeWasmFunction(value as JSFunction, null);
  }
  if (value.typeofEquals('object')) {
    // A Dart object that went out boxed by [jsifyMixed] (dart2wasm).
    try {
      return (value as JSBoxedDartObject).toDart;
    } catch (_) {}
  }
  return value;
}

List<Object?> _resultsToDart(JSAny? result, List<ValueTy>? types) {
  if (result == null || result.isUndefinedOrNull) {
    // dart2wasm does not tell undefined (void) from null (a null externref).
    return types != null && types.isNotEmpty ? [null] : const [];
  }
  if (jsIsArray(result)) {
    final values = (result as JSArray<JSAny?>).toDart;
    return [
      for (var i = 0; i < values.length; i++)
        _toDart(values[i], types != null && i < types.length ? types[i] : null),
    ];
  }
  return List.filled(1, _toDart(result, types?.firstOrNull));
}

/// A Dart closure taking [arity] positional arguments (as upstream's
/// `WasmFunction.inner`, which was the JS function itself under dart2js).
Function _positional(int arity, List<Object?> Function([List<Object?>?]) call) {
  return ([Object? a0, Object? a1, Object? a2, Object? a3, Object? a4, Object? a5, Object? a6, Object? a7, Object? a8, Object? a9, Object? a10, Object? a11, Object? a12, Object? a13, Object? a14, Object? a15]) {
    final all = [a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15];
    final r = call(all.sublist(0, arity < all.length ? arity : all.length));
    return r.isEmpty ? null : (r.length == 1 ? r.first : r);
  };
}

WasmFunction _makeWasmFunction(JSFunction value, String? name) {
  final ty = _getFuncType(value);
  final params = ty?.parameters.cast<ValueTy?>() ??
      List<ValueTy?>.filled((value['length']! as JSNumber).toDartInt, null);

  List<Object?> call([List<Object?>? args]) {
    final a = args ?? const [];
    final jsArgs = [
      for (var i = 0; i < a.length; i++)
        _toJs(a[i], i < params.length ? params[i] : null),
    ].toJS;
    // callMethodVarArgs: callMethod(m, null, x) would drop every argument
    // after the first null one.
    final result =
        value.callMethodVarArgs<JSAny?>('apply'.toJS, [null, jsArgs]);
    return _resultsToDart(result, ty?.results);
  }

  final function = WasmFunction(
    _positional(params.length, call),
    name: name,
    params: params,
    call: call,
    // results is not supported on web https://github.com/WebAssembly/js-types/blob/main/proposals/js-types/Overview.md
    results: ty?.results,
  );
  _jsFunctions[function] = value;
  return function;
}

/// A JS function that calls the host (Dart) function [f] from wasm.
///
/// PATCHED (xprs): the i64 boundary. The browser's WebAssembly API hands an
/// `i64` parameter to a JS import as a `BigInt` and requires a `BigInt` back
/// for an `i64` result; a host function declared `results: [ValueTy.i64]`
/// that returned a plain int made every call throw `TypeError: Cannot convert
/// 1788797831 to a BigInt` (hal_time_epoch). i64 params reach the Dart
/// function as `int`, as on native. Under dart2wasm every other value needs
/// the same treatment (a JS Number is not a Dart int there), so every import
/// is wrapped now and converted by its declared [WasmFunction.params] /
/// [WasmFunction.results].
JSFunction _importFunction(WasmFunction f) {
  final params = f.params;
  final results = f.results;

  JSAny? call(List<JSAny?> args) {
    final converted = List<Object?>.generate(args.length, (i) {
      final ty = i < params.length ? params[i] : null;
      final arg = args[i];
      if (ty == ValueTy.i64 && arg != null) return i64.toInt(arg);
      return _toDart(arg, ty);
    });
    final r = Function.apply(f.inner, converted);
    if (results != null && results.length == 1) return _toJs(r, results.first);
    if (results != null && results.isEmpty) return null;
    if (r is List) {
      return [
        for (var i = 0; i < r.length; i++)
          _toJs(r[i], results != null && i < results.length ? results[i] : null),
      ].toJS;
    }
    return _toJs(r, null);
  }

  switch (params.length) {
    case 0:
      return (() => call([])).toJS;
    case 1:
      return ((JSAny? a0) => call([a0])).toJS;
    case 2:
      return ((JSAny? a0, JSAny? a1) => call([a0, a1])).toJS;
    case 3:
      return ((JSAny? a0, JSAny? a1, JSAny? a2) => call([a0, a1, a2])).toJS;
    case 4:
      return ((JSAny? a0, JSAny? a1, JSAny? a2, JSAny? a3) => call([a0, a1, a2, a3])).toJS;
    case 5:
      return ((JSAny? a0, JSAny? a1, JSAny? a2, JSAny? a3, JSAny? a4) => call([a0, a1, a2, a3, a4])).toJS;
    case 6:
      return ((JSAny? a0, JSAny? a1, JSAny? a2, JSAny? a3, JSAny? a4, JSAny? a5) => call([a0, a1, a2, a3, a4, a5])).toJS;
    case 7:
      return ((JSAny? a0, JSAny? a1, JSAny? a2, JSAny? a3, JSAny? a4, JSAny? a5, JSAny? a6) => call([a0, a1, a2, a3, a4, a5, a6])).toJS;
    case 8:
      return ((JSAny? a0, JSAny? a1, JSAny? a2, JSAny? a3, JSAny? a4, JSAny? a5, JSAny? a6, JSAny? a7) => call([a0, a1, a2, a3, a4, a5, a6, a7])).toJS;
    case 9:
      return ((JSAny? a0, JSAny? a1, JSAny? a2, JSAny? a3, JSAny? a4, JSAny? a5, JSAny? a6, JSAny? a7, JSAny? a8) => call([a0, a1, a2, a3, a4, a5, a6, a7, a8])).toJS;
    case 10:
      return ((JSAny? a0, JSAny? a1, JSAny? a2, JSAny? a3, JSAny? a4, JSAny? a5, JSAny? a6, JSAny? a7, JSAny? a8, JSAny? a9) => call([a0, a1, a2, a3, a4, a5, a6, a7, a8, a9])).toJS;
    case 11:
      return ((JSAny? a0, JSAny? a1, JSAny? a2, JSAny? a3, JSAny? a4, JSAny? a5, JSAny? a6, JSAny? a7, JSAny? a8, JSAny? a9, JSAny? a10) => call([a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10])).toJS;
    case 12:
      return ((JSAny? a0, JSAny? a1, JSAny? a2, JSAny? a3, JSAny? a4, JSAny? a5, JSAny? a6, JSAny? a7, JSAny? a8, JSAny? a9, JSAny? a10, JSAny? a11) => call([a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11])).toJS;
    case 13:
      return ((JSAny? a0, JSAny? a1, JSAny? a2, JSAny? a3, JSAny? a4, JSAny? a5, JSAny? a6, JSAny? a7, JSAny? a8, JSAny? a9, JSAny? a10, JSAny? a11, JSAny? a12) => call([a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12])).toJS;
    case 14:
      return ((JSAny? a0, JSAny? a1, JSAny? a2, JSAny? a3, JSAny? a4, JSAny? a5, JSAny? a6, JSAny? a7, JSAny? a8, JSAny? a9, JSAny? a10, JSAny? a11, JSAny? a12, JSAny? a13) => call([a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13])).toJS;
    case 15:
      return ((JSAny? a0, JSAny? a1, JSAny? a2, JSAny? a3, JSAny? a4, JSAny? a5, JSAny? a6, JSAny? a7, JSAny? a8, JSAny? a9, JSAny? a10, JSAny? a11, JSAny? a12, JSAny? a13, JSAny? a14) => call([a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14])).toJS;
    case 16:
      return ((JSAny? a0, JSAny? a1, JSAny? a2, JSAny? a3, JSAny? a4, JSAny? a5, JSAny? a6, JSAny? a7, JSAny? a8, JSAny? a9, JSAny? a10, JSAny? a11, JSAny? a12, JSAny? a13, JSAny? a14, JSAny? a15) => call([a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12, a13, a14, a15])).toJS;
    default:
      throw UnsupportedError(
          'imported function ${f.name} has ${params.length} params; the web '
          'bridge converts up to 16');
  }
}

class _SharedMemory extends _Memory implements WasmSharedMemory {
  _SharedMemory(super.memory, super._type);

  @override
  int atomicNotify(int addr, int count) {
    return atomics.notify(view, addr, count);
  }

  @override
  SharedMemoryWaitResult atomicWait32(int addr, int expected) {
    final value = atomics.wait(view, addr, expected, null);
    switch (value) {
      case 'ok':
        return SharedMemoryWaitResult.ok;
      case 'not-equal':
        return SharedMemoryWaitResult.mismatch;
      case 'timed-out':
        return SharedMemoryWaitResult.timedOut;
      default:
        throw Exception('atomicWait32 Unexpected value: $value');
    }
  }

  @override
  SharedMemoryWaitResult atomicWait64(int addr, int expected) {
    throw UnimplementedError('atomicWait64 is not supported on web');
  }
}

class _Memory extends WasmMemory {
  final JsWasmMemory memory;
  @override
  final MemoryTy? type;

  _Memory(this.memory, MemoryTy? type)
      : type = type ?? _getMemoryType(memory);

  @override
  void grow(int deltaPages) {
    memory.grow(deltaPages);
  }

  @override
  int get lengthInBytes => memory.lengthInBytes;

  @override
  int get lengthInPages => memory.lengthInPages;

  /// A view of the current buffer (JS-backed under dart2wasm, not a copy);
  /// as upstream, take a new one after the memory grows.
  @override
  Uint8List get view => memory.buffer.toDart.asUint8List();
}

class _Global extends WasmGlobal {
  final JsWasmGlobal global;
  @override
  final GlobalTy? type;
  final WasmValue? _initialValue;

  _Global(this.global, GlobalTy? type, this._initialValue)
      : type = type ?? _getGlobalType(global);

  @override
  Object? get() => _toDart(global.value, type?.value);

  @override
  void set(WasmValue value) {
    global.value = _toJs(value.value, value.type);
  }
}

class _Table extends WasmTable {
  final JsWasmTable table;
  @override
  final TableTy? type;
  final WasmValue? _initialValue;

  _Table(this.table, TableTy? type, this._initialValue)
      : type = type ?? _getTableType(table);

  @override
  void set(int index, WasmValue value) {
    table.set(index, _toJs(value.value, value.type));
  }

  @override
  Object? get(int index) {
    final v = table.get(index);
    if (v != null && v.typeofEquals('function')) {
      return _makeWasmFunction(v as JSFunction, null);
    }
    return _toDart(v, type?.element);
  }

  @override
  int get length => table.length;

  @override
  int grow(int delta, WasmValue fillValue) {
    final previous = table.grow(delta);
    if (fillValue.value != null) {
      for (var i = previous; i < table.length; i++) {
        set(i, fillValue);
      }
    }
    return previous;
  }
}

ExternalType? _getExternalType(JSObject value) {
  final type = _getType(value);
  if (type == null) return null;
  if (type['mutable'] is bool && type['value'] is String) {
    return ExternalType.global(_getGlobalType(value)!);
  } else if (type['element'] is String && type['minimum'] is int) {
    return ExternalType.table(_getTableType(value)!);
  } else if (type['shared'] is bool && type['minimum'] is int) {
    return ExternalType.memory(_getMemoryType(value)!);
  } else if (type.containsKey('results') && type.containsKey('parameters')) {
    final params = (type['parameters'] as List?)?.cast<String>();
    final results = (type['results'] as List?)?.cast<String>();
    if (params == null || results == null) return null;
    return ExternalType.func(
      FuncTy(
        parameters: params.map(ValueTy.values.byName).toList(),
        results: results.map(ValueTy.values.byName).toList(),
      ),
    );
  } else {
    return null;
  }
}
String valueTypeToJson(ValueTy ty) {
  return ty.name;
}

Map<String, Object?> typeToJson(ExternalType ty) {
  return ty.when(
    func: (func) => {
      'parameters': func.parameters.map(valueTypeToJson).toList(),
      'results': func.results.map(valueTypeToJson).toList(),
    },
    global: (global) => {
      'value': valueTypeToJson(global.value),
      'mutable': global.mutable,
    },
    table: (table) => {
      'element': valueTypeToJson(table.element),
      'minimum': table.minimum,
      'initial': table.minimum,
      if (table.maximum != null) 'maximum': table.maximum,
    },
    memory: (memory) => {
      'shared': memory.shared,
      'minimum': memory.minimum,
      'initial': memory.minimum,
      if (memory.maximum != null) 'maximum': memory.maximum,
    },
  );
}

MemoryTy? _getMemoryType(JSObject value) {
  final t = _getType(value);
  if (t == null) return null;
  return MemoryTy(
    shared: t['shared'] == true,
    minimum: t['minimum']! as int,
    maximum: t['maximum'] as int?,
  );
}

GlobalTy? _getGlobalType(JSObject value) {
  final t = _getType(value);
  if (t == null) return null;
  final ty = ValueTy.values.byName(t['value']! as String);
  return GlobalTy(
    value: ty,
    mutable: t['mutable'] == true,
  );
}

TableTy? _getTableType(JSObject value) {
  final t = _getType(value);
  if (t == null) return null;
  final ty = ValueTy.values.firstWhere(
    (value) =>
        value.name.toLowerCase() == (t['element']! as String).toLowerCase(),
  );
  return TableTy(
    element: ty,
    minimum: t['minimum']! as int,
    maximum: t['maximum'] as int?,
  );
}

FuncTy? _getFuncType(JSFunction value) {
  final type = _getType(value);
  if (type == null) return null;
  final params = (type['parameters'] as List?)
      ?.cast<String>()
      .map(ValueTy.values.byName)
      .toList();
  final results = (type['results'] as List?)
      ?.cast<String>()
      .map(ValueTy.values.byName)
      .toList();
  if (results == null || params == null) {
    return null;
  }
  return FuncTy(parameters: params, results: results);
}

/// The type-reflection descriptor of [value] (js-types proposal), if the
/// browser has it: a `type()` method on functions, globals, memories and
/// tables, or a `type` property on module import/export descriptors.
Map<String, Object?>? _getType(JSObject value) {
  if (!value.has('type')) return null;
  final type = value['type'];
  final descriptor = type != null && type.typeofEquals('function')
      ? value.callMethod<JSAny?>('type'.toJS)
      : type;
  final dart = dartifyJson(descriptor);
  return dart is Map ? dart.cast() : null;
}
