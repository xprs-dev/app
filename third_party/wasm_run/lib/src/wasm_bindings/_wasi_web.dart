// ignore_for_file: public_member_api_docs, non_constant_identifier_names

/// import { WASI, File, OpenFile, PreopenDirectory } from "@bjorn3/browser_wasi_shim";
/// let args = ["bin", "arg1", "arg2"];
/// let env = ["FOO=bar"];
/// let fds = [
///     new OpenFile(new File([])), // stdin
///     new OpenFile(new File([])), // stdout
///     new OpenFile(new File([])), // stderr
///     new PreopenDirectory(".", {
///         "example.c": new File(new TextEncoder("utf-8").encode(`#include "a"`)),
///         "hello.rs": new File(new TextEncoder("utf-8").encode(`fn main() { println!("Hello World!"); }`)),
///     }),
/// ];
/// let wasi = new WASI(args, env, fds);
//
// PATCHED (xprs): ported from package:js / dart:js_util to dart:js_interop so
// it compiles under dart2wasm as well as dart2js. The shim's classes are read
// from `globalThis.browser_wasi_shim` (set by assets/browser_wasi_shim.js).
// Byte arrays cross with toJS/toDart: under dart2wasm a WasiWebFile holds a
// copy of the Dart bytes it was created from, as the shim's File is created
// once from them. See README.xprs.md.
@JS('browser_wasi_shim')
library browser_wasi_shim;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

const oflagsCREAT = 1 << 0;
const oflagsDIRECTORY = 1 << 1;
const oflagsEXCL = 1 << 2;
const oflagsTRUNC = 1 << 3;

@JS('File')
extension type WasiWebFile._(JSObject _) implements JSObject {
  factory WasiWebFile(Uint8List data) => WasiWebFile._new(data.toJS);
  external factory WasiWebFile._new(JSUint8Array data);
  @JS('data')
  external JSUint8Array get _data;
  Uint8List get data => _data.toDart;
}

@JS('Directory')
extension type WasiWebDirectory._(JSObject _) implements JSObject {
  /// [items]: a JS object of name -> File | Directory.
  external factory WasiWebDirectory(JSObject items);
}

@JS('OpenFile')
extension type OpenFile._(JSObject _) implements Fd {
  external factory OpenFile(WasiWebFile file);
  external WasiWebFile get file;
}

@JS('OpenDirectory')
extension type OpenDirectory._(JSObject _) implements Fd {
  external factory OpenDirectory(WasiWebDirectory dir);
  external WasiWebDirectory get dir;
}

@JS('PreopenDirectory')
extension type PreopenDirectory._(JSObject _) implements OpenDirectory {
  external factory PreopenDirectory(
    String name,
    JSObject items, // { [name]: File | Directory }
  );
  @JS('prestat_name')
  external JSUint8Array get _prestatName;
  Uint8List get prestat_name => _prestatName.toDart;
}

@JS('WASI')
extension type WASI._(JSObject _) implements JSObject {
  /// Create a new WASI instance.
  external factory WASI(
    JSArray<JSString> args,
    // ["FOO=bar""]
    JSArray<JSString> env,
    JSArray<Fd> fds,
  );
  external JSArray<JSString> get args;
  // ["FOO=bar""]
  external JSArray<JSString> get env;
  @JS('fds')
  external JSArray<Fd> get _fds;
  List<Fd> get fds => _fds.toDart;

  /// The `wasi_snapshot_preview1` import object: name -> function.
  external JSObject get wasiImport;

  external void start(JSObject /*Instance*/ instance);
  external void initialize(JSObject /*Instance*/ instance);
}

typedef IntOrBigInt = JSAny; // number | BigInt;

class WasiStdio {
  ///
  WasiStdio() {
    fd['fd_write'] = ((JSUint8Array view8, JSArray<Iovec> iovs) =>
        fd_write(view8.toDart, iovs.toDart)).toJS;
  }

  final Fd fd = Fd();
  final streamController = StreamController<Uint8List>.broadcast();

  NwrittenGet fd_write(Uint8List view8, List<Iovec> iovs) {
    var nwritten = 0;
    for (final iovec in iovs) {
      final buffer = view8.sublist(iovec.buf, iovec.buf + iovec.buf_len);
      streamController.add(buffer);
      nwritten += iovec.buf_len;
    }
    return NwrittenGet(ret: 0, nwritten: nwritten);
  }
}

@JS('strace')
external JSObject strace(JSObject instance, JSArray<JSString> no_trace);

@JS('Iovec')
extension type Iovec._(JSObject _) implements JSObject {
  external int get buf;
  external int get buf_len;
}

@JS('Filestat')
extension type Filestat._(JSObject _) implements JSObject {}

@JS('Fdstat')
extension type Fdstat._(JSObject _) implements JSObject {}

typedef FstFlags = JSAny?;
typedef Atim = JSAny?;
typedef Mtim = JSAny?;
typedef Flags = JSAny?;
typedef OldFlags = JSAny?;
typedef Dirflags = JSAny?;
typedef Oflags = JSAny?;
typedef FsRightsBase = JSAny?;
typedef FsRightsInheriting = JSAny?;
typedef Fdflags = JSAny?;

@JS('Fd')
extension type Fd._(JSObject _) implements JSObject {
  external factory Fd();

  external int fd_advise(IntOrBigInt offset, JSBigInt len, IntOrBigInt advice);
  external int fd_allocate(IntOrBigInt offset, JSBigInt len);
  external int fd_close();
  external int fd_datasync();
  external FdstatGet fd_fdstat_get();
  external int fd_fdstat_set_flags(int flags);
  external int fd_fdstat_set_rights(
      JSBigInt fs_rights_base, JSBigInt fs_rights_inheriting);
  external FilestatGet fd_filestat_get();
  external int fd_filestat_set_size(IntOrBigInt size);
  external int fd_filestat_set_times(Atim atim, Mtim mtim, FstFlags fst_flags);
  external Read fd_pread(
      JSUint8Array view8, JSArray<Iovec> iovs, IntOrBigInt offset);
  external PrestatGet fd_prestat_get();
  external PrestatDirNameGet fd_prestat_dir_name(int path_ptr, int path_len);
  external NwrittenGet fd_pwrite(
      JSUint8Array view8, JSArray<Iovec> iovs, IntOrBigInt offset);
  external Read fd_read(JSUint8Array view8, JSArray<Iovec> iovs);
  external DirentGet fd_readdir_single(JSBigInt cookie);
  external OffsetGet fd_seek(IntOrBigInt offset, int whence);
  external int fd_sync();
  external OffsetGet fd_tell();
  external NwrittenGet fd_write(JSUint8Array view8, JSArray<Iovec> iovs);
  external int path_create_directory(String path);
  external FilestatGet path_filestat_get(Flags flags, String path);
  external void path_filestat_set_times(
      Flags flags, String path, Atim atim, Mtim mtim, FstFlags fst_flags);
  external int path_link(
      int old_fd, OldFlags old_flags, String old_path, String new_path);
  external FdObjGet path_open(
      Dirflags dirflags,
      String path,
      Oflags oflags,
      FsRightsBase fs_rights_base,
      FsRightsInheriting fs_rights_inheriting,
      Fdflags fdflags);
  external DataGet path_readlink(String path);
  external int path_remove_directory(String path);
  external int path_rename(String old_path, int new_fd, String new_path);
  external int path_symlink(String old_path, String new_path);
  external int path_unlink_file(String path);
}

extension type Read._(JSObject _) implements JSObject {
  external int get ret;
  external int get nread;
}

extension type FilestatGet._(JSObject _) implements JSObject {
  external int get ret;
  external Filestat? get filestat;
}

extension type FdstatGet._(JSObject _) implements JSObject {
  external int get ret;
  external Fdstat? get fdstat;
}

extension type OffsetGet._(JSObject _) implements JSObject {
  external int get ret;
  external JSAny get offset;
}

extension type NwrittenGet._(JSObject _) implements JSObject {
  external int get ret;
  external int get nwritten;

  external factory NwrittenGet({
    required int ret,
    required int nwritten,
  });
}

extension type PrestatGet._(JSObject _) implements JSObject {
  external int get ret;
  external JSAny? get prestat;
}

extension type PrestatDirNameGet._(JSObject _) implements JSObject {
  external int get ret;
  external JSUint8Array? get prestat_dir_name;
}

extension type DirentGet._(JSObject _) implements JSObject {
  external int get ret;
  external JSAny? get dirent;
}

extension type FdObjGet._(JSObject _) implements JSObject {
  external int get ret;
  external JSObject? get fd_obj;
}

extension type DataGet._(JSObject _) implements JSObject {
  external int get ret;
  external JSAny? get data;
}
