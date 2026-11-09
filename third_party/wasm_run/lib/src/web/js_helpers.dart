// PATCHED (xprs): shared dart:js_interop helpers for the browser half of
// wasm_run. They replace dart:js_util / package:js, which dart2wasm cannot
// compile, and behave the same under dart2js. See README.xprs.md.
// ignore_for_file: public_member_api_docs

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

@JS('BigInt')
external JSBigInt jsBigInt(JSAny value);

/// JS `String(value)`; works on primitives such as a `BigInt`, which are not
/// JS objects and so have no `callMethod`.
@JS('String')
external JSString jsString(JSAny? value);

@JS('Object.assign')
external JSObject objectAssign(JSObject target, JSAny? a, [JSAny? b]);

@JS('Object.keys')
external JSArray<JSString> objectKeys(JSObject value);

@JS('Array.isArray')
external bool jsIsArray(JSAny? value);

/// A new empty JS object `{}`.
JSObject newJsObject() => JSObject();

/// Whether [value] is a JS value (always true under dart2js, where every
/// object is one; under dart2wasm only for values that came from JS).
// ignore: invalid_runtime_check_with_js_interop_types
bool isJsValue(Object? value) => value is JSAny;

/// Converts a Dart value — primitives, lists, maps, typed data, values that
/// already are JS — to JS. A Dart object with no JS form is boxed, so it can
/// travel through JS (e.g. as an `externref`) and come back.
JSAny? jsifyMixed(Object? value) {
  if (value == null) return null;
  if (value is String) return value.toJS;
  if (value is num) return value.toJS;
  if (value is bool) return value.toJS;
  if (value is ByteBuffer) return value.toJS;
  if (value is Uint8List) return value.toJS;
  if (value is TypedData) return value.jsify();
  if (value is List) return [for (final e in value) jsifyMixed(e)].toJS;
  if (value is Map) {
    final object = JSObject();
    value.forEach((k, v) => object[k.toString()] = jsifyMixed(v));
    return object;
  }
  // ignore: invalid_runtime_check_with_js_interop_types
  if (value is JSAny) return value;
  return value.toJSBox;
}

/// Converts a JS number to a Dart `int` when it is integral, else `double`.
/// (Under dart2js the two are the same thing; under dart2wasm they are not.)
num jsNumberToDart(JSNumber value) {
  final d = value.toDartDouble;
  if (d.isFinite && d == d.truncateToDouble()) return d.toInt();
  return d;
}

/// Converts JSON-like JS data (numbers, strings, booleans, arrays, plain
/// objects) to Dart. A `BigInt`, a function or any other JS object is kept
/// as the JS value, so an i64 stays a JS `BigInt` ([I64] on the web).
Object? dartifyJson(JSAny? value) {
  if (value == null || value.isUndefinedOrNull) return null;
  if (value.typeofEquals('number')) return jsNumberToDart(value as JSNumber);
  if (value.typeofEquals('string')) return (value as JSString).toDart;
  if (value.typeofEquals('boolean')) return (value as JSBoolean).toDart;
  if (!value.typeofEquals('object')) return value; // bigint, function, symbol
  if (jsIsArray(value)) {
    return (value as JSArray<JSAny?>).toDart.map(dartifyJson).toList();
  }
  final object = value as JSObject;
  final ctor = object['constructor'];
  final plain = ctor == null ||
      ctor.isUndefinedOrNull ||
      (ctor as JSObject)['name'].dartify() == 'Object';
  if (!plain) return value;
  return {
    for (final key in objectKeys(object).toDart)
      key.toDart: dartifyJson(object[key.toDart]),
  };
}
