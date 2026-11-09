// PATCHED (xprs): ported from package:js to dart:js_interop so it compiles
// under dart2wasm as well as dart2js. See README.xprs.md.
import 'dart:js_interop';

@JS('wasmFeatureDetect')
external WasmFeatureDetect get wasmFeatureDetect;

/// The `wasm-feature-detect` library object; every member resolves to
/// whether the browser supports that WebAssembly feature.
extension type WasmFeatureDetect._(JSObject _) implements JSObject {
  /// BigInt integration
  external JSPromise<JSBoolean> bigInt();

  /// Bulk memory operations
  external JSPromise<JSBoolean> bulkMemory();

  /// Exception handling
  external JSPromise<JSBoolean> exceptions();

  /// Extented Const Expressesions
  external JSPromise<JSBoolean> extendedConst();

  /// Garbage Collection
  external JSPromise<JSBoolean> gc();

  /// JavaScript Promise Integration
  external JSPromise<JSBoolean> jspi();

  /// Memory64
  external JSPromise<JSBoolean> memory64();

  /// Multi-value
  external JSPromise<JSBoolean> multiValue();

  /// Importable/Exportable mutable globals
  external JSPromise<JSBoolean> mutableGlobals();

  /// Reference Types
  external JSPromise<JSBoolean> referenceTypes();

  /// Relaxed SIMD
  external JSPromise<JSBoolean> relaxedSimd();

  /// Non-trapping float-to-int conversions
  external JSPromise<JSBoolean> saturatedFloatToInt();

  /// Sign-extension operators
  external JSPromise<JSBoolean> signExtensions();

  /// Fixed-Width SIMD
  external JSPromise<JSBoolean> simd();

  /// Streaming Compilation
  external JSPromise<JSBoolean> streamingCompilation();

  /// Tail call
  external JSPromise<JSBoolean> tailCall();

  /// Threads
  external JSPromise<JSBoolean> threads();
}

/// Awaits one feature check as a Dart bool.
Future<bool> featureToFuture(JSPromise<JSBoolean> check) =>
    check.toDart.then((value) => value.toDart);
