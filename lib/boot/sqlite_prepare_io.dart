import 'dart:io' show Platform;

import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';
import 'package:sqlite3/open.dart';

/// Android ships SQLCipher (sqlcipher_flutter_libs) under its own name;
/// desktop and iOS resolve the bundled library under the default names.
void prepareAppSqlite() {
  if (Platform.isAndroid) {
    open.overrideFor(OperatingSystem.android, openCipherOnAndroid);
  }
}
