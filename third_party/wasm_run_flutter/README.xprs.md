# Why this package is vendored

Fork of `wasm_run_flutter 0.1.0` (pub.dev). The Dart code is upstream. What
changed is where `libwasm_run_dart.so` comes from.

Upstream's Android and Linux `CMakeLists.txt` downloaded
`github.com/juancastillo0/wasm_run/releases/download/wasm_run-v0.1.0/*.tar.gz`
at build time and packaged the prebuilt library inside it, which had been
compiled in 2023 on a macOS CI runner. That was a network call to GitHub on
every clean build, and a binary nobody could rebuild from this tree. F-Droid
accepts neither.

Both platforms now compile the Rust crate in `third_party/wasm_run/native`:

| Platform | How | Engine |
|---|---|---|
| Android | `android/build.gradle`: task `cargoBuildWasmRun` runs `native/build-android.sh` before `preBuild`, for the ABIs in `-Ptarget-platform`, linking with the app's NDK clang | wasmtime on arm64-v8a/x86_64, wasmi on armeabi-v7a/x86 |
| Linux | `linux/CMakeLists.txt`: a custom target runs `cargo build --release --locked` for the host | wasmtime |

The engine split, the version pins and the exported symbols all match
upstream's release. Both `wire_*` export tables were compared with
`llvm-nm -D` against the prebuilt libraries and came out identical. The one
deliberate difference is wasmi 0.31.2 instead of 0.31.0, which is yanked on
crates.io. As a side effect, the arm64 library is now 16 KB page-aligned (NDK
r28 default), which Android 15+ devices with 16 KB pages require. The 2023
prebuilt was 4 KB-aligned.

Windows, macOS and iOS are untouched and still fetch upstream's prebuilt
libraries. None of them is an F-Droid target.

## Requirements

`cargo` and `rustup` on the PATH. The script adds a missing Android target
itself. The first Android build of one ABI takes about 2 minutes on the
development laptop; after that cargo rebuilds only what changed. The cargo
target directory is `third_party/wasm_run/native/target` (gitignored), which
`flutter clean` does not touch.

## Upgrading

If `wasm_run_flutter` is updated, keep `android/build.gradle` and
`linux/CMakeLists.txt` from this fork and take the rest from upstream. If
the Rust crate is updated, regenerate both lockfiles (see
`third_party/wasm_run/README.xprs.md` section 6) and compare the `wire_*`
exports again.
