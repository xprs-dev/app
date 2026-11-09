// PATCHED (xprs): ported from package:js to dart:js_interop so it compiles
// under dart2wasm as well as dart2js. See README.xprs.md.
library html_typed_data;

import 'dart:collection';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'dart:typed_data' hide Int64List, Uint64List;

import '../helpers.dart' show UnmodifiableTypedListException;
export 'dart:typed_data' hide Int64List, Uint64List;

@JS('BigInt')
external JSBigInt _jsBigInt(JSAny value);

@JS('String')
external JSString _jsString(JSAny? value);

/// A JS `BigInt` from a Dart int, via its decimal string so that no bit is
/// lost (a Dart int is 64-bit under dart2wasm, a JS Number is not).
JSBigInt _bigIntFromInt(int value) => _jsBigInt(value.toString().toJS);

/// `%TypedArray%` members shared by `BigInt64Array` and `BigUint64Array`.
extension type TypedArray._(JSObject _) implements JSObject {
  ByteBuffer get buffer =>
      (getProperty<JSArrayBuffer>('buffer'.toJS)).toDart;
  int get length => getProperty<JSNumber>('length'.toJS).toDartInt;
  JSAny? at(int index) => callMethod<JSAny?>('at'.toJS, index.toJS);
  void operator []=(int index, JSAny? value) => setProperty(index.toJS, value);
}

JSObject _newTypedArray(
    String ctor, Object lengthOrBuffer, int? offset, int? length) {
  final c = globalContext[ctor]! as JSFunction;
  final JSAny first;
  if (lengthOrBuffer is int) {
    first = lengthOrBuffer.toJS;
  } else if (lengthOrBuffer is ByteBuffer) {
    // Under dart2wasm a Dart-allocated buffer is copied here, so a "view" of
    // it does not alias the Dart bytes; a JS-backed buffer is shared.
    first = lengthOrBuffer.toJS;
  } else {
    // ignore: invalid_runtime_check_with_js_interop_types
    first = lengthOrBuffer as JSAny;
  }
  if (offset == null && length == null) return c.callAsConstructor(first);
  return c.callAsConstructor(first, (offset ?? 0).toJS, length?.toJS);
}

extension type BigInt64Array._(JSObject _) implements TypedArray {
  factory BigInt64Array(Object lengthOrBuffer, [int? offset, int? length]) =>
      BigInt64Array._(
          _newTypedArray('BigInt64Array', lengthOrBuffer, offset, length));

  factory BigInt64Array.fromList(List<int> list) {
    final array = BigInt64Array(list.length);
    for (var i = 0; i < list.length; i++) {
      array[i] = _bigIntFromInt(list[i]);
    }
    return array;
  }

  factory BigInt64Array.view(
    ByteBuffer buffer, [
    int offset = 0,
    int? length,
  ]) =>
      BigInt64Array(buffer, offset, length);

  factory BigInt64Array.sublistView(TypedData array,
          [int offset = 0, int? length]) =>
      BigInt64Array(array.buffer, offset, length);
}

extension type BigUint64Array._(JSObject _) implements TypedArray {
  factory BigUint64Array(Object lengthOrBuffer, [int? offset, int? length]) =>
      BigUint64Array._(
          _newTypedArray('BigUint64Array', lengthOrBuffer, offset, length));

  factory BigUint64Array.fromList(List<int> list) {
    final array = BigUint64Array(list.length);
    for (var i = 0; i < list.length; i++) {
      array[i] = _bigIntFromInt(list[i]);
    }
    return array;
  }

  factory BigUint64Array.view(ByteBuffer buffer,
          [int offset = 0, int? length]) =>
      BigUint64Array(buffer, offset, length);

  factory BigUint64Array.sublistView(TypedData array,
          [int offset = 0, int? length]) =>
      BigUint64Array(array.buffer, offset, length);
}

/// Opt out of type safety for setting the value.
/// Helpful if the array needs to accept multiple types.
abstract class _SetAnyListMixin<T> extends ListMixin<T> {
  @override
  void operator []=(int index, dynamic value) {
    this[index] = value;
  }
}

abstract class TypedList<T> extends _SetAnyListMixin<T> {
  TypedArray get inner;

  /// How to cast a raw JS value to an acceptable Dart value.
  T js2dart(Object? value);

  /// How to convert a Dart integer-like value to an acceptable JS value.
  JSAny? dart2js(Object? value);

  @override
  T operator [](int index) => js2dart(inner.at(index));

  @override
  void operator []=(int index, value) {
    inner[index] = dart2js(value);
  }

  @override
  int get length => inner.length;

  @override
  set length(int newLength) => throw UnmodifiableTypedListException();

  ByteBuffer get buffer => inner.buffer;
}

BigInt _castBigInt(Object bigInt) {
  // ignore: invalid_runtime_check_with_js_interop_types
  return BigInt.parse(_jsString(bigInt as JSAny).toDart);
}

JSAny _convertBigInt(Object dart) {
  if (dart is int) return _bigIntFromInt(dart);
  if (dart is BigInt) return _jsBigInt(dart.toString().toJS);
  // Assume value is already JS safe.
  // ignore: invalid_runtime_check_with_js_interop_types
  return dart as JSAny;
}

class Int64List extends TypedList<BigInt> {
  @override
  final BigInt64Array inner;
  Int64List.from(this.inner);

  @override
  BigInt js2dart(Object? value) => _castBigInt(value!);

  @override
  JSAny? dart2js(Object? value) => _convertBigInt(value!);

  factory Int64List(int length) => Int64List.from(BigInt64Array(length));
  factory Int64List.fromList(List<int> list) =>
      Int64List.from(BigInt64Array.fromList(list));
  factory Int64List.view(ByteBuffer buffer, [int offset = 0, int? length]) =>
      Int64List.from(BigInt64Array.view(buffer, offset, length));
  factory Int64List.sublistView(TypedData array,
          [int offset = 0, int? length]) =>
      Int64List.from(BigInt64Array.sublistView(array, offset, length));
}

class Uint64List extends TypedList<BigInt> {
  @override
  final BigUint64Array inner;
  Uint64List.from(this.inner);

  @override
  BigInt js2dart(Object? value) => _castBigInt(value!);

  @override
  JSAny? dart2js(Object? value) => _convertBigInt(value!);

  factory Uint64List(int length) => Uint64List.from(BigUint64Array(length));
  factory Uint64List.fromList(List<int> list) =>
      Uint64List.from(BigUint64Array.fromList(list));
  factory Uint64List.view(ByteBuffer buffer, [int offset = 0, int? length]) =>
      Uint64List.from(BigUint64Array.view(buffer, offset, length));
  factory Uint64List.sublistView(TypedData array,
          [int offset = 0, int? length]) =>
      Uint64List.from(BigUint64Array.sublistView(array, offset, length));
}
