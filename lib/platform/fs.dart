/*
 * Filesystem seam.
 *
 * Every file or directory the core touches goes through [fs], a
 * package:file `FileSystem`, instead of dart:io's `File`/`Directory`. The
 * API is the dart:io one (sync variants included -- the WASM HAL callbacks
 * need them), so a port is `File(p)` -> `fs.file(p)`; what changes is the
 * backing store: the local disk on desktop and mobile, and an in-memory tree
 * persisted to the browser's IndexedDB on web, where dart:io compiles but
 * every call throws at runtime.
 *
 * [initFs] is awaited once at boot (storage_paths.initStorageRoot) before any
 * storage access: a no-op natively, the IndexedDB hydration on web.
 * [flushFs] forces pending web writes out; call it after anything a reload
 * must not lose (profiles.json, keys).
 */

export 'fs_web.dart' if (dart.library.io) 'fs_io.dart';
