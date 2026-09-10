# Why this package is vendored

Fork of `wasm_run 0.1.0+2` (pub.dev, published 2023 — still the newest release,
so there is no upstream fix to wait for). Everything is upstream except two
edits in `lib/src/wasm_bindings/_wasm_interop_native.dart`, both marked
`PATCHED (xprs)`.

## 1. The host-callback ABI was wrong on 32-bit ARM

Rust declares the wasm→host trampoline as

```rust
// native/src/api_wasmi.rs:634 (also api.rs / api_wasmtime.rs:1014)
type WasmFunction =
    unsafe extern "C" fn(function_id: u32, args: *mut DartAbi) -> *mut wire_list_wasm_val;
```

but the Dart typedef declared the first parameter as `ffi.Int64`.

* **AAPCS64** (arm64 phones, x86_64 desktop): every integral argument gets its
  own register, so Dart read `w0`/`x1` and Rust had written `w0`/`x1`. Correct
  by luck.
* **AAPCS32** (armeabi-v7a): a 64-bit argument must occupy an even-aligned
  *core register pair*. Dart's trampoline therefore expected the id in `r0:r1`
  and the args pointer in **r2**, while Rust passed that pointer in **r1**.

Dart then dereferenced a stale register as a `Dart_CObject*`:

```
_globalWasmFunction error: Exception: Can't read invalid data type -509558769
Fatal signal 11 (SIGSEGV), fault addr 0x0
```

`-509558769` is `0xE1A0C00F`, the ARM32 encoding of `mov ip, pc` — the first
word of a PLT veneer. The "type" field it read was executable code, which is
what proves this was a wrong-register read and not a struct-layout problem
(`Dart_CObject`'s layout is pointer-size correct on both ABIs).

Every wasm→host call was broken on 32-bit ARM, whatever the function's
signature. Observed on a Lenovo TB300FU (Android 13, `abilist64` empty): the
app crash-looped seconds after each launch, because a background wapp engine
starts on boot and Chat calls `hal_time_epoch` several times a second.

The fix is `ffi.Uint32`, matching Rust. 64-bit targets are unaffected.

## 2. A failing host function segfaulted the process

The callback caught, printed and **rethrew**. An exception escaping an FFI
callback yields the default return — `nullptr` — and Rust immediately does
`box_from_leak_ptr(result)` (`bridge_generated.rs:4085`), dereferencing address
0. So any host-side error was a native crash on *every* ABI, uncatchable from
Dart. It now returns an empty `wire_list_wasm_val`, which Rust sees as an empty
`Vec<WasmVal>` and reports as an ordinary wasm trap.

## Upgrading

If a newer `wasm_run` ever ships, diff these two hunks against it; if upstream
has fixed both, drop the `dependency_overrides` entry in `pubspec.yaml` and
delete this directory. `example/` and `test/` were removed to keep the tree
small. `native/` is the Rust source that `libwasm_run_dart.so` is built from
on Android and Linux (section 6). The patches in sections 1 and 2 are
Dart-side only.

## 3. Web: the i64 boundary of imported host functions

`lib/src/wasm_bindings/_wasm_interop_web.dart`, `_importFunction`, marked
`PATCHED (xprs)`. The browser's WebAssembly API passes an `i64` parameter to a
JS import as a `BigInt` and requires a `BigInt` back for an `i64` result.
Upstream handed the Dart closure straight to the import object, so a host
function declared `results: [ValueTy.i64]` returned a JS `Number` and every
call threw `TypeError: Cannot convert 1788797831 to a BigInt` (`hal_time_epoch`,
once a second, on every wapp). Functions whose signature names an `i64` are now
wrapped at the boundary; the rest pass through untouched.

## 4. Web: the WASI shim is vendored

`lib/assets/browser_wasi_shim.js` imported `@bjorn3/browser_wasi_shim@0.2.9`
from jsdelivr at runtime, so a web build needed the internet to start a wapp.
The package's `dist/` (Apache-2.0) is vendored under
`lib/assets/browser_wasi_shim/` and the import points there.

## 5. No download from github.com at run time

`wasm_run_flutter` registers `WasmRunFlutterNative.registerWith()`, which runs
at every app start and calls `WasmRunLibrary.setUp(override: false)`. Upstream,
if the bundled `libwasm_run_dart.so` failed to load, `setUp` fetched
`github.com/juancastillo0/wasm_run/releases/.../other.tar.gz`, ran `tar` on it
and loaded the result. That is a network call to GitHub from a shipped binary,
and it executes code nobody built from this source tree.

`setUp` (in `lib/src/ffi.dart`) and the native `setUpLibraryImpl` (in
`lib/src/ffi/io.dart`) now do nothing on native platforms, both marked
`PATCHED (xprs)`. `setup_dynamic_library.dart`, `cpu_architecture.dart` and the
`bin/setup.dart` CLI that used them are deleted. A missing library is reported
by `defaultInstance()` when the first module is compiled. The web path is
unchanged.

The build-time download, in `wasm_run_flutter`'s CMake, is gone as well
(section 6).

## 6. `native/` is built, not just kept

`third_party/wasm_run_flutter` (also vendored) compiles this crate instead of
downloading upstream's prebuilt library. The changes that made that possible:

* `build.rs` is deleted, along with its `flutter_rust_bridge_codegen`
  build-dependency. It re-ran the bridge generator on every build and
  rewrote `lib/src/bridge_generated*.dart`, which would have overwritten the
  patched Dart here. It also needed LLVM and a Dart SDK at build time.
  `src/bridge_generated.rs` is committed, so the generator is not needed.
* The versions upstream actually shipped are pinned exactly:
  `flutter_rust_bridge =1.82.4`, `wasmtime`/`wasmtime-wasi`/`wasi-common
  =14.0.4`, and `wasmi`/`wasmi_wasi =0.31.2`. wasmi 0.31.2 replaces 0.31.0,
  which is yanked. The pins were read from the strings in upstream's `.so`.
* `Cargo.lock` (wasmtime) and `Cargo.wasmi.lock` (wasmi) are committed, and
  every build uses `--locked`.
* `build-android.sh` builds one ABI at a time with the NDK's clang as linker.
  32-bit ABIs get the wasmi manifest and `src/api_wasmi.rs` as `api.rs` in a
  staging copy, because wasmtime has no 32-bit ARM backend. That is also what
  upstream shipped.

Regenerating a lockfile after changing a manifest:

```sh
cd third_party/wasm_run/native
CARGO_RESOLVER_INCOMPATIBLE_RUST_VERSIONS=fallback cargo generate-lockfile
# wasmi: the same, in target/wasmi-src after one armeabi-v7a build, then
cp target/wasmi-src/Cargo.lock Cargo.wasmi.lock
```
