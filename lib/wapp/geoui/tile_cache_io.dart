// Disk-cached map tiles (native/desktop). A tile is fetched once, written to
// ~/.local/share/xprs/cache/tiles, and served from disk afterwards — so the
// map keeps working off-grid once an area has been viewed. Integrates with
// Flutter's in-memory ImageCache via the ImageProvider key, so panning back to
// a recent tile is instant and re-opening the app reads from disk, not the net.

import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

ImageProvider tileImageProvider(String url) => _DiskTile(url);

/// Tile servers ask every client to say who it is (OpenStreetMap's usage
/// policy refuses the generic library agent); one value for viewing and for
/// saving an area.
const Map<String, String> _tileHeaders = {
  'User-Agent': 'XPRS/1 (+https://xprs.dev)',
};

File _tileFile(String url) =>
    File('${_cacheDir()}/${sha256.convert(utf8.encode(url)).toString()}.tile');

/// Save [urls] into the same disk cache the map reads, for using the map
/// off-grid. Tiles already held are skipped. Two at a time with a pause
/// between, because a tile server is shared and a prefetch is a burst it did
/// not ask for: callers keep the list small (tile_math's cap) and only fetch
/// when a person asked to save an area. [onProgress] reports done/total;
/// [cancelled] stops it between tiles. Returns how many tiles are now held.
Future<int> prefetchTiles(List<String> urls,
    {void Function(int done, int total)? onProgress,
    bool Function()? cancelled}) async {
  var done = 0, held = 0;
  final client = http.Client();
  try {
    for (var i = 0; i < urls.length; i += 2) {
      if (cancelled?.call() ?? false) break;
      final batch = urls.skip(i).take(2).toList();
      final got = await Future.wait(batch.map((url) async {
        final file = _tileFile(url);
        try {
          if (await file.exists() && await file.length() > 0) return true;
          final resp = await client
              .get(Uri.parse(url), headers: _tileHeaders)
              .timeout(const Duration(seconds: 20));
          if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) return false;
          await file.parent.create(recursive: true);
          await file.writeAsBytes(resp.bodyBytes);
          return true;
        } catch (_) {
          return false;
        }
      }));
      held += got.where((g) => g).length;
      done += batch.length;
      onProgress?.call(done, urls.length);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
  } finally {
    client.close();
  }
  return held;
}

String _cacheDir() {
  final home = Platform.environment['HOME'] ??
      Platform.environment['USERPROFILE'] ??
      Directory.systemTemp.path;
  return '$home/.local/share/xprs/cache/tiles';
}

/// A tile's bytes as served: from the disk cache, else from the network
/// (then kept on disk for next time and for off-grid use).
Future<Uint8List> tileBytes(String url) async {
  final file = _tileFile(url);
  try {
    if (await file.exists()) {
      final bytes = await file.readAsBytes();
      if (bytes.isNotEmpty) return bytes;
    }
  } catch (_) {/* fall through to network */}
  final resp = await http.get(Uri.parse(url), headers: _tileHeaders);
  final bytes = resp.bodyBytes;
  if (resp.statusCode == 200 && bytes.isNotEmpty) {
    try {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
    } catch (_) {/* cache write is best-effort */}
    return bytes;
  }
  throw NetworkImageLoadException(
      statusCode: resp.statusCode, uri: Uri.parse(url));
}

class _DiskTile extends ImageProvider<_DiskTile> {
  final String url;
  _DiskTile(this.url);

  @override
  Future<_DiskTile> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_DiskTile>(this);

  @override
  ImageStreamCompleter loadImage(_DiskTile key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1.0,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async =>
      decode(await ui.ImmutableBuffer.fromUint8List(await tileBytes(url)));

  @override
  bool operator ==(Object other) => other is _DiskTile && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
