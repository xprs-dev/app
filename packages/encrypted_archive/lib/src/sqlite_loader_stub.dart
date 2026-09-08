/// Web: no default. The host loads sqlite3.wasm, registers an IndexedDB VFS
/// and sets [SQLiteLoader.override]; reaching here means it did not.
library;

import 'package:sqlite3/common.dart';

Never _notInjected() => throw StateError(
    'encrypted_archive: SQLiteLoader.override not set -- on web the host '
    'must inject a sqlite3.wasm-backed opener before opening an archive');

CommonDatabase openDatabase(String dbPath) => _notInjected();

CommonDatabase openInMemory() => _notInjected();
