/// `<platform>-<arch>` key for the running host, matching a wapp manifest's
/// `provides.native_binaries` keys. Null where no native binary can run --
/// every browser, and any ABI not mapped. dart:ffi's `Abi` is the only way to
/// learn the architecture, and dart:ffi does not compile on web, hence the
/// split.
library;

export 'native_abi_stub.dart' if (dart.library.ffi) 'native_abi_io.dart';
