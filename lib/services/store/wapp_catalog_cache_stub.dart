/// Web catalog cache: memory only, gone with the tab. The store still works,
/// it just fetches the catalog again next time.
library;

import 'dart:typed_data';

class CatalogCache {
  final _mem = <String, Uint8List>{};
  final _when = <String, DateTime>{};
  CatalogCache({String? dir});

  Future<Uint8List?> read(String key) async => _mem[key];

  Future<DateTime?> modified(String key) async => _when[key];

  Future<void> write(String key, List<int> bytes) async {
    _mem[key] = Uint8List.fromList(bytes);
    _when[key] = DateTime.now();
  }
}
