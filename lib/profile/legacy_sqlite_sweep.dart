/// Removes the SQLite files of earlier builds, once (legacy_sqlite_sweep_io).
library;

export 'legacy_sqlite_sweep_stub.dart'
    if (dart.library.io) 'legacy_sqlite_sweep_io.dart';
