# PATCHED (xprs): builds libwasm_run_dart.so from the Rust source in
# third_party/wasm_run/native with cargo, instead of downloading a prebuilt
# one from github.com. See third_party/wasm_run_flutter/README.xprs.md.

# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

project(wasm_run_flutter LANGUAGES CXX)

# This directory is reached through flutter/ephemeral/.plugin_symlinks. CMake
# collapses ".." before it follows a symlink, so resolve this directory first
# and only then walk up to the crate.
get_filename_component(PluginDir "${CMAKE_CURRENT_SOURCE_DIR}" REALPATH)
get_filename_component(RustCrate "${PluginDir}/../../wasm_run/native" ABSOLUTE)
set(RustTargetDir "${RustCrate}/target/wasmtime")
set(RustLib "${RustTargetDir}/release/libwasm_run_dart.so")

find_program(CARGO cargo HINTS "$ENV{HOME}/.cargo/bin" REQUIRED)

# Always run: cargo decides what is out of date, and does nothing when the
# crate has not changed. At most 4 jobs, for the memory of a small machine.
add_custom_target(wasm_run_dart_rust ALL
  COMMAND ${CMAKE_COMMAND} -E env CARGO_BUILD_JOBS=4
          ${CARGO} build --release --locked
          --manifest-path "${RustCrate}/Cargo.toml"
          --target-dir "${RustTargetDir}"
  WORKING_DIRECTORY "${RustCrate}"
  BYPRODUCTS "${RustLib}"
  COMMENT "wasm_run: cargo build (wasmtime)"
  VERBATIM
)

# List of absolute paths to libraries that should be bundled with the plugin.
set(wasm_run_flutter_bundled_libraries
  "${RustLib}"
  PARENT_SCOPE
)
