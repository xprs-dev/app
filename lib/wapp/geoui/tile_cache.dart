// Cross-platform map-tile image provider: a disk-backed cache on native
// (desktop/mobile) for off-grid use, and a plain NetworkImage on web.

import 'package:flutter/widgets.dart';

import 'tile_cache_web.dart' if (dart.library.io) 'tile_cache_io.dart' as impl;

/// An ImageProvider for a tile URL that caches to disk where possible.
ImageProvider tileImageProvider(String url) => impl.tileImageProvider(url);

/// Save tiles for off-grid use (native only; see tile_cache_io.dart).
Future<int> prefetchTiles(List<String> urls,
        {void Function(int done, int total)? onProgress,
        bool Function()? cancelled}) =>
    impl.prefetchTiles(urls, onProgress: onProgress, cancelled: cancelled);
