// PATCHED (xprs): ported from dart:html + package:js to dart:js_interop so the
// web half compiles under dart2wasm as well as dart2js. See README.xprs.md.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart';

// Upstream re-exported package:js (`JS`, `anonymous`) and two js_util helpers
// for generated code. The js_interop annotations take their place.
export 'dart:js_interop' show JS, anonymous;

abstract class WasmModule {
  Object call([String? moduleName]);

  /// Create a new WASM module initializer that is bound to the specified binary.
  WasmModule bind(dynamic thisArg, String moduleName);

  static Future<T> cast<T extends WasmModule>(FutureOr<WasmModule> module) {
    return Future.value(module).then((module) => module as T);
  }

  static FutureOr<WasmModule> initialize(
          {required Modules kind, WasmModule Function()? module}) =>
      kind.initializeModule(module);
}

abstract class Modules {
  const Modules();

  const factory Modules.noModules({required String root}) =
      _WasmBindgenNoModules;

  FutureOr<WasmModule> initializeModule(WasmModule Function()? module);

  void _ensureCrossOriginIsolated() {
    switch (crossOriginIsolated) {
      case false:
        throw const MissingHeaderException();
      case true:
      case null:
        warn(
            'Warning: crossOriginIsolated is null, browser might not support buffer sharing.');
        return;
    }
  }
}

class _WasmBindgenNoModules extends Modules {
  final String root;
  const _WasmBindgenNoModules({required this.root});

  @override
  FutureOr<WasmModule> initializeModule(WasmModule Function()? module) {
    _ensureCrossOriginIsolated();
    return _injectScript('$root.js').then((_) {
      eval('window.wasm_bindgen = wasm_bindgen');
      final module_ = module?.call() ?? _noModules!;
      return module_.bind(null, '${root}_bg.wasm');
    });
  }
}

/// Appends `<script src=...>` to the document head and completes on `load`.
Future<void> _injectScript(String src) {
  final document = globalContext['document']! as JSObject;
  final script = document.callMethod<JSObject>('createElement'.toJS, 'script'.toJS);
  script['src'] = src.toJS;
  final loaded = Completer<void>();
  script.callMethod<JSAny?>(
    'addEventListener'.toJS,
    'load'.toJS,
    ((JSAny? _) {
      if (!loaded.isCompleted) loaded.complete();
    }).toJS,
  );
  script.callMethod<JSAny?>(
    'addEventListener'.toJS,
    'error'.toJS,
    ((JSAny? _) {
      if (!loaded.isCompleted) {
        loaded.completeError(Exception('Failed to load script $src'));
      }
    }).toJS,
  );
  (document['head']! as JSObject).callMethod<JSAny?>('append'.toJS, script);
  return loaded.future;
}

typedef ExternalLibrary = FutureOr<WasmModule>;
typedef DartPostCObject = void;

@JS('crossOriginIsolated')
external bool? get crossOriginIsolated;

@JS('console.warn')
external void _consoleWarn(JSAny? a, [JSAny? b, JSAny? c, JSAny? d]);

/// Converts a Dart value to something JS can hold: primitives map to their JS
/// counterparts, JS values pass through, anything else becomes its string.
JSAny? _toJs(Object? value) {
  if (value == null) return null;
  if (value is String) return value.toJS;
  if (value is num) return value.toJS;
  if (value is bool) return value.toJS;
  // ignore: invalid_runtime_check_with_js_interop_types
  if (value is JSAny) return value;
  return value.toString().toJS;
}

void warn([Object? a, Object? b, Object? c, Object? d]) =>
    _consoleWarn(_toJs(a), _toJs(b), _toJs(c), _toJs(d));

@JS('Number')
external JSNumber _number(JSAny? value);

int castInt(Object? value) {
  if (value is int) return value;
  return _number(_toJs(value)).toDartDouble.toInt();
}

@JS('BigInt')
external JSBigInt _bigInt(JSAny? value);

Object castNativeBigInt(Object? value) {
  // A Dart int is 64-bit under dart2wasm, so go through its decimal string
  // rather than a JS Number to keep every bit.
  if (value is int || value is BigInt) return _bigInt(value.toString().toJS);
  return _bigInt(_toJs(value));
}

@JS('Function')
extension type _Function._(JSFunction _) implements JSFunction {
  external factory _Function(String script);
}

/// A `wasm_bindgen` module object exposed by its `-t no-modules` loader.
class _JsWasmModule implements WasmModule {
  final JSFunction _fn;
  _JsWasmModule(this._fn);

  @override
  Object call([String? moduleName]) =>
      _fn.callAsFunction(null, moduleName?.toJS) ?? Object();

  @override
  WasmModule bind(dynamic thisArg, String moduleName) => _JsWasmModule(
        _fn.callMethodVarArgs<JSFunction>(
            'bind'.toJS, [_toJs(thisArg), moduleName.toJS]),
      );
}

@JS('wasm_bindgen')
external JSFunction? get _wasmBindgen;

WasmModule? get _noModules {
  final fn = _wasmBindgen;
  return fn == null ? null : _JsWasmModule(fn);
}

dynamic eval(String script) => _Function(script).callAsFunction();

abstract class DartApiDl {}

@JS('wasm_bindgen.get_dart_object')
// ignore: non_constant_identifier_names
external JSAny _getDartObject(int ptr);

Object getDartObject(int ptr) => _getDartObject(ptr);

@JS('wasm_bindgen.drop_dart_object')
// ignore: non_constant_identifier_names
external void dropDartObject(int ptr);

abstract class FlutterRustBridgeWireBase {
  void storeDartPostCObject() {}
  // ignore: non_constant_identifier_names
  void free_WireSyncReturn(WireSyncReturn raw) {}

  // ignore: non_constant_identifier_names
  Object get_dart_object(int ptr) {
    return getDartObject(ptr);
  }

  // ignore: non_constant_identifier_names
  void drop_dart_object(int ptr) {
    dropDartObject(ptr);
  }

  // ignore: non_constant_identifier_names
  int new_dart_opaque(Object obj, NativePortType port) {
    throw UnimplementedError();
  }
}

typedef WireSyncReturn = List<dynamic>;

List<dynamic> wireSyncReturnIntoDart(WireSyncReturn syncReturn) => syncReturn;

class FlutterRustBridgeWasmWireBase<T extends WasmModule>
    extends FlutterRustBridgeWireBase {
  final Future<T> init;

  FlutterRustBridgeWasmWireBase(FutureOr<T> module)
      : init = Future.value(module).then((module) async {
          final promise = module();
          // ignore: invalid_runtime_check_with_js_interop_types
          if (promise is JSPromise) await promise.toDart;
          return module;
        });
}

typedef PlatformPointer = int;
typedef OpaqueTypeFinalizer = Finalizer<PlatformPointer>;

/// An opaque pointer to a Rust type.
/// Recipients of this type should call [dispose] at least once during runtime.
/// If passed to a native function after being [dispose]d, an exception will be thrown.
class FrbOpaqueBase {
  static PlatformPointer initPtr(int ptr) => ptr;
  static PlatformPointer nullPtr() => 0;
  static bool isStalePtr(PlatformPointer ptr) => ptr == 0;
  static void finalizerAttach(FrbOpaqueBase opaque, PlatformPointer ptr, int _,
          OpaqueTypeFinalizer finalizer) =>
      finalizer.attach(opaque, ptr, detach: opaque);
}
