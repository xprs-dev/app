// Cross-platform map-tile image provider: a disk-backed cache on native
// (desktop/mobile) for off-grid use, and a plain NetworkImage on web.

import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:xprs_core/src/platform/off_thread.dart';

import 'tile_cache_web.dart' if (dart.library.io) 'tile_cache_io.dart' as impl;
import 'tile_recolor.dart';

/// An ImageProvider for a tile URL that caches to disk where possible. A
/// [style] that recolours (tile_recolor.dart's isRecolorStyle) repaints the
/// tile's pixels once, off the UI isolate, as it is decoded; the disk keeps
/// the tile as served, so a style change needs no new download.
ImageProvider tileImageProvider(String url, {String style = ''}) =>
    isRecolorStyle(style) ? _RecoloredTile(url, style) : impl.tileImageProvider(url);

/// Save tiles for off-grid use (native only; see tile_cache_io.dart).
Future<int> prefetchTiles(List<String> urls,
        {void Function(int done, int total)? onProgress,
        bool Function()? cancelled}) =>
    impl.prefetchTiles(urls, onProgress: onProgress, cancelled: cancelled);

Uint8List _recolor(Uint8List px) => recolorDark(px);

class _RecoloredTile extends ImageProvider<_RecoloredTile> {
  final String url, style;
  const _RecoloredTile(this.url, this.style);

  @override
  Future<_RecoloredTile> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_RecoloredTile>(this);

  @override
  ImageStreamCompleter loadImage(_RecoloredTile key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1.0, debugLabel: url);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await impl.tileBytes(url);
    final codec = await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    final frame = await codec.getNextFrame();
    final img = frame.image;
    final w = img.width, h = img.height;
    final data = await img.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    img.dispose();
    codec.dispose();
    if (data == null) throw StateError('tile $url: no pixels');
    final px = await offThread(_recolor, data.buffer.asUint8List(),
        debugLabel: 'tile-recolor');
    final buf = await ui.ImmutableBuffer.fromUint8List(px);
    final desc = ui.ImageDescriptor.raw(buf,
        width: w, height: h, pixelFormat: ui.PixelFormat.rgba8888);
    return desc.instantiateCodec();
  }

  @override
  bool operator ==(Object other) =>
      other is _RecoloredTile && other.url == url && other.style == style;

  @override
  int get hashCode => Object.hash(url, style);
}
