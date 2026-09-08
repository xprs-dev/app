/// Flutter targets: the host app bundles the native SQLite library (XPRS
/// depends on sqlcipher_flutter_libs directly), so this opens through
/// package:sqlite3's default resolution and keeps encrypted_archive a pure
/// Dart package.
library;

import 'package:sqlite3/common.dart';
import 'package:sqlite3/sqlite3.dart';

CommonDatabase openDatabase(String dbPath) => sqlite3.open(dbPath);

CommonDatabase openInMemory() => sqlite3.openInMemory();
