/// Native catalog cache: `<support>/store/<key>` files. A write goes to a
/// `.part` first and is renamed into place, so a crash mid-write leaves
/// the previous copy readable.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class CatalogCache {
  final String? _dirOverride;
  String? _dir;
  CatalogCache({String? dir}) : _dirOverride = dir;

  Future<String> _base() async {
    if (_dir != null) return _dir!;
    final base = _dirOverride ??
        '${(await getApplicationSupportDirectory()).path}/store';
    await Directory(base).create(recursive: true);
    return _dir = base;
  }

  /// The most a cached document may be: a catalog of every app is tens of
  /// KB, an icon SVG is capped at 256 KiB by the service that stores it.
  static const maxBytes = 1 << 20;

  Future<Uint8List?> read(String key) async {
    try {
      final f = File('${await _base()}/$key');
      if (!await f.exists()) return null;
      if (await f.length() > maxBytes) return null;
      // arch-ignore: no-whole-file-read a catalog JSON or an icon SVG, refused above 1 MiB
      return await f.readAsBytes();
    } catch (_) {
      return null;
    }
  }

  Future<DateTime?> modified(String key) async {
    try {
      final f = File('${await _base()}/$key');
      if (!await f.exists()) return null;
      return (await f.stat()).modified;
    } catch (_) {
      return null;
    }
  }

  Future<void> write(String key, List<int> bytes) async {
    try {
      final path = '${await _base()}/$key';
      final tmp = File('$path.part');
      await tmp.parent.create(recursive: true);
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(path);
    } catch (_) {}
  }
}
