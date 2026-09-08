/// Native half of the filesystem seam: the real disk.
library;

import 'package:file/file.dart';
import 'package:file/local.dart';

const FileSystem fs = LocalFileSystem();

Future<void> initFs() async {}

Future<void> flushFs() async {}

String get pathSeparator => fs.path.separator;
