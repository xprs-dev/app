// ignore_for_file: public_member_api_docs

// PATCHED (xprs): ported from dart:js_util to dart:js_interop so it compiles
// under dart2wasm as well as dart2js. The 64-bit reads and writes go through
// two 32-bit halves in Dart: calling DataView.getBigInt64 on `ByteData.toJS`
// would, under dart2wasm, act on a copy of a Dart-allocated buffer, so a
// write would be lost. See README.xprs.md.

import 'dart:js_interop';
import 'dart:typed_data';

import 'package:wasm_run/src/web/js_helpers.dart';

typedef I64 = Object; // JsBigInt

I64 int64FromIntImpl(int value) {
  // Through the decimal string: a Dart int is 64-bit under dart2wasm and a
  // JS Number would drop bits above 2^53.
  return jsBigInt(value.toString().toJS);
}

I64 int64FromBigIntImpl(BigInt value) {
  return jsBigInt(value.toString().toJS);
}

String _str(I64 value) {
  if (value is int || value is BigInt) return value.toString();
  // ignore: invalid_runtime_check_with_js_interop_types
  return jsString(value as JSAny).toDart;
}

int toIntImpl(I64 value) {
  if (value is int) return value;
  return BigInt.parse(_str(value)).toSigned(64).toInt();
}

BigInt toBigIntImpl(I64 value) {
  return BigInt.parse(_str(value));
}

final _mask32 = BigInt.from(0xffffffff);

BigInt _read64(ByteData array, int index, Endian endian, {required bool signed}) {
  final little = endian == Endian.little;
  final lo = array.getUint32(little ? index : index + 4, endian);
  final hi = signed
      ? array.getInt32(little ? index + 4 : index, endian)
      : array.getUint32(little ? index + 4 : index, endian);
  return (BigInt.from(hi) << 32) | BigInt.from(lo);
}

void _write64(ByteData array, int index, Object value, Endian endian) {
  final little = endian == Endian.little;
  final v = toBigIntImpl(value).toUnsigned(64);
  final lo = (v & _mask32).toInt();
  final hi = ((v >> 32) & _mask32).toInt();
  array.setUint32(little ? index : index + 4, lo, endian);
  array.setUint32(little ? index + 4 : index, hi, endian);
}

I64 getInt64Bytes(ByteData array, int index, Endian endian) {
  return int64FromBigIntImpl(_read64(array, index, endian, signed: true));
}

I64 getUint64Bytes(ByteData array, int index, Endian endian) {
  return int64FromBigIntImpl(_read64(array, index, endian, signed: false));
}

void setInt64Bytes(ByteData array, int index, Object value, Endian endian) {
  _write64(array, index, value, endian);
}

void setUint64Bytes(ByteData array, int index, Object value, Endian endian) {
  _write64(array, index, value, endian);
}

// @JS('DataView')
// abstract class DataView {
//   ///
//   external factory DataView(ByteBuffer buffer,
//       [int? byteOffset, int? byteLength]);
//   external int get length;
//   external int get byteLength;
//   external int get byteOffset;
//   external ByteBuffer get buffer;

//   external void setBigUint64(int byteOffset, JsBigInt value,
//      bool littleEndian);
//   external void setBigInt64(int byteOffset, JsBigInt value,
//      bool littleEndian);
//   external JsBigInt getBigInt64(int byteOffset, bool littleEndian);
//   external JsBigInt getBigUint64(int byteOffset, bool littleEndian);
// }

// @JS('BigInt64Array')
// abstract class BigInt64Array {
//   external factory BigInt64Array(Object lengthOrArrayLike);

//   external int get length;
//   external int get byteLength;
//   external int get byteOffset;
//   external ByteBuffer get buffer;
//   external void fill(Int64 value);
//   external Int64 at(int index);
//   external void set(int index, Int64 value);
//   external BigInt64Array slice(int start, int end);
//   external BigInt64Array subarray(int begin, int end);
// }

// @JS('BigUint64Array')
// abstract class BigUint64Array {
//   external factory BigUint64Array(Object lengthOrArrayLike);

//   external int get length;
//   external int get byteLength;
//   external int get byteOffset;
//   external ByteBuffer get buffer;
//   external void fill(Int64 value);
//   external Int64 at(int index);
//   external void set(int index, Int64 value);
//   external BigUint64Array slice(int start, int end);
//   external BigUint64Array subarray(int begin, int end);
// }

// class Int64 {
//   final Object _jsBigInt;

//   Int64(this._jsBigInt);

//   factory Int64.fromString(String value) {
//     return Int64(_jsBigIntConstruct(value));
//   }
//   @override
//   String toString() {
//     return callMethod(_jsBigInt, 'toString', const []) as String;
//   }
// }
