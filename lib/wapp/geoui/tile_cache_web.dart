// Web fallback for map tiles: the browser already caches network images, so
// we just hand back a plain NetworkImage (no dart:io disk cache on web).

import 'package:flutter/widgets.dart';

ImageProvider tileImageProvider(String url) => NetworkImage(url);

/// The browser caches tiles itself; saving an area is a native feature.
Future<int> prefetchTiles(List<String> urls,
        {void Function(int done, int total)? onProgress,
        bool Function()? cancelled}) async =>
    0;
