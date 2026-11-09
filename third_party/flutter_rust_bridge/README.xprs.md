# Why this package is vendored

Copy of `flutter_rust_bridge 1.82.6` (pub.dev), the runtime half of the bridge
that `wasm_run`'s generated bindings (`third_party/wasm_run/lib/src/bridge_generated*.dart`)
are written against. It is pulled in by `wasm_run` only; the app does not use
it directly. `example/`, `test/`, `README.md` and `CHANGELOG.md` were dropped.

## The change: the web half builds under dart2wasm

The dart2wasm web build (`flutter build web --wasm`) failed on this package
(and on `wasm_run`) alone among the app's dependencies, for two reasons:

1. **Conditional imports keyed on `dart.library.html`.** dart2wasm does not
   provide `dart:html`, so `dart.library.html` is false there and every
   `import 'ffi/io.dart' if (dart.library.html) 'ffi/web.dart'` picked the
   `dart:ffi` half, which dart2wasm cannot compile. They are now keyed on
   `dart.library.js_interop`, which is true under dart2js and dart2wasm and
   false on the native VM:

   | file | native VM | dart2js | dart2wasm |
   |---|---|---|---|
   | `src/ffi.dart` (import + export) | `ffi/io.dart` | `ffi/web.dart` | `ffi/web.dart` |
   | `src/ffi/stub.dart` (import + export) | `io.dart` | `web.dart` | `web.dart` |
   | `src/isolate.dart` | `isolate/io.dart` | `isolate/web.dart` | `isolate/web.dart` |
   | `src/load.dart` | `load/load.io.dart` | `load/load.web.dart` | `load/load.web.dart` |
   | `src/typed_data.dart` | `typed_data/io.dart` | `typed_data/web.dart` | `typed_data/web.dart` |

2. **The web halves used `dart:html` and `package:js`**, neither of which
   dart2wasm compiles. `src/ffi/web.dart`, `src/isolate/web.dart` and
   `src/typed_data/web.dart` are ported to `dart:js_interop` /
   `dart:js_interop_unsafe` (marked `PATCHED (xprs)`). The `js` dependency is
   gone from `pubspec.yaml`; the SDK floor is 3.3 (extension types).

What the port keeps and what it does not:

* Names and signatures used by generated code are unchanged, except that
  `ffi/web.dart` now re-exports `JS`/`anonymous` from `dart:js_interop`
  instead of `package:js`, and no longer re-exports `promiseToFuture` /
  `getProperty`. `BigInt64Array`/`BigUint64Array`/`TypedArray` are extension
  types over `JSObject` instead of `@JS` classes. `PortLike` no longer extends
  dart:html's `EventTarget`; it keeps `postMessage`, `close`, `nativePort`,
  `addEventListener`/`removeEventListener` (taking a `JSFunction`) and gains
  `onMessage` (the `dartify`d `data` of each `message` event).
* `wasm_bindgen` (the `-t no-modules` loader global) is wrapped in a Dart
  `WasmModule` adapter rather than being cast to one, since a JS object can
  no longer pose as a Dart class.
* Under dart2wasm, `Int64List.view(buffer)` of a **Dart-allocated** buffer
  views a copy (`ByteBuffer.toJS` copies there); a JS-backed buffer is shared.

None of this is exercised by the app: `wasm_run` never loads its Rust library
in a browser (`createLibraryImpl` throws on the web and its browser path uses
the WebAssembly JS API directly), so on the web this package only has to
compile. Rust-over-wasm_bindgen through this bridge is untested after the port.

## Upgrading

flutter_rust_bridge 2.x is a different API; `wasm_run`'s generated code is
for 1.82.x. If `wasm_run` is ever regenerated against a newer bridge whose
web half no longer uses `dart:html` / `package:js`, drop the
`dependency_overrides` entry in the app's `pubspec.yaml` and delete this
directory.
