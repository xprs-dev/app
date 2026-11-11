// Web fallback for map tiles: the browser already caches network images, so
// we just hand back a plain NetworkImage (no dart:io disk cache on web).

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

ImageProvider tileImageProvider(String url) => NetworkImage(url);

/// The browser caches tiles itself; saving an area is a native feature.
Future<int> prefetchTiles(List<String> urls,
        {void Function(int done, int total)? onProgress,
        bool Function()? cancelled}) async =>
    0;

/// A tile's bytes, for recolouring (the browser's cache serves repeats).
Future<Uint8List> tileBytes(String url) async {
  final resp = await http.get(Uri.parse(url));
  if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) return resp.bodyBytes;
  throw NetworkImageLoadException(statusCode: resp.statusCode, uri: Uri.parse(url));
}
