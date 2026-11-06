/// Removes the storage files of earlier builds, once (legacy_storage_sweep_io).
library;

export 'legacy_storage_sweep_stub.dart'
    if (dart.library.io) 'legacy_storage_sweep_io.dart';
