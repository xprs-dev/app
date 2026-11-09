// PATCHED (xprs): direct dart:js_interop bindings for the browser's
// WebAssembly JS API. They replace package:wasm_interop 2.0.1, which is
// written with package:js and so cannot be compiled by dart2wasm. Only what
// _wasm_interop_web.dart uses is bound. See README.xprs.md.
// ignore_for_file: public_member_api_docs

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('WebAssembly.Module')
extension type JsWasmModule._(JSObject _) implements JSObject {
  /// Synchronous compile: `new WebAssembly.Module(bytes)`.
  external JsWasmModule(JSAny bytesOrBuffer);

  external static JSArray<JsWasmDescriptor> imports(JsWasmModule module);
  external static JSArray<JsWasmDescriptor> exports(JsWasmModule module);
}

/// An entry of `WebAssembly.Module.imports()` / `.exports()`.
extension type JsWasmDescriptor._(JSObject _) implements JSObject {
  /// Only on imports.
  external String get module;
  external String get name;

  /// "function" | "table" | "memory" | "global" | "tag"
  external String get kind;
}

@JS('WebAssembly.Instance')
extension type JsWasmInstance._(JSObject _) implements JSObject {
  /// Synchronous instantiation: `new WebAssembly.Instance(module, imports)`.
  external JsWasmInstance(JsWasmModule module, JSObject imports);
  external JSObject get exports;
}

@JS('WebAssembly.compile')
external JSPromise<JsWasmModule> wasmCompile(JSAny bytesOrBuffer);

/// `WebAssembly.instantiate(module, imports)`; given a compiled module it
/// resolves to the Instance itself.
@JS('WebAssembly.instantiate')
external JSPromise<JsWasmInstance> wasmInstantiateModule(
  JsWasmModule module,
  JSObject imports,
);

@JS('WebAssembly.Memory')
extension type JsWasmMemory._(JSObject _) implements JSObject {
  external JsWasmMemory._new(JSObject descriptor);

  factory JsWasmMemory({
    required int initial,
    int? maximum,
    bool shared = false,
  }) {
    final d = JSObject()..['initial'] = initial.toJS;
    if (maximum != null) d['maximum'] = maximum.toJS;
    if (shared) d['shared'] = true.toJS;
    return JsWasmMemory._new(d);
  }

  external JSArrayBuffer get buffer;

  /// Returns the previous size in pages.
  external int grow(int delta);

  int get lengthInBytes => (buffer['byteLength']! as JSNumber).toDartInt;
  int get lengthInPages => lengthInBytes >> 16;
}

@JS('WebAssembly.Table')
extension type JsWasmTable._(JSObject _) implements JSObject {
  external JsWasmTable._new(JSObject descriptor, [JSAny? value]);

  /// [element] is "anyfunc" (funcref) or "externref".
  factory JsWasmTable({
    required String element,
    required int initial,
    int? maximum,
    JSAny? value,
  }) {
    final d = JSObject()
      ..['element'] = element.toJS
      ..['initial'] = initial.toJS;
    if (maximum != null) d['maximum'] = maximum.toJS;
    return value == null ? JsWasmTable._new(d) : JsWasmTable._new(d, value);
  }

  /// Returns the previous length.
  external int grow(int delta);
  external JSAny? get(int index);
  external void set(int index, JSAny? value);
  external int get length;
}

@JS('WebAssembly.Global')
extension type JsWasmGlobal._(JSObject _) implements JSObject {
  external JsWasmGlobal._new(JSObject descriptor, [JSAny? value]);

  /// [valueType] is "i32" | "i64" | "f32" | "f64" | "externref" | "anyfunc".
  factory JsWasmGlobal(String valueType, JSAny? value, {required bool mutable}) {
    final d = JSObject()
      ..['value'] = valueType.toJS
      ..['mutable'] = mutable.toJS;
    return value == null ? JsWasmGlobal._new(d) : JsWasmGlobal._new(d, value);
  }

  external JSAny? get value;
  external set value(JSAny? value);
}
