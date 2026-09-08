// A picture too large for the packet lane gets a small version that fits it,
// so a photograph reaches somebody on another network at all (XPRS.md 7.7.6:
// the packet lane is the only one that crosses a shared internet transport).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:xprs/services/media/media_preview.dart';

/// A photo-shaped source: big, noisy, and therefore not trivially compressible.
Uint8List _photo(int w, int h) {
  final im = img.Image(width: w, height: h);
  var seed = 7;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      im.setPixelRgb(x, y, seed & 0xff, (seed >> 8) & 0xff, (seed >> 16) & 0xff);
    }
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: 92));
}

void main() {
  test('a large photograph shrinks to something the packet lane carries', () {
    final source = _photo(1600, 1200);
    expect(source.length, greaterThan(kInlinePacketCapForTest),
        reason: 'the source has to be too big for the lane, or there is '
            'nothing to prove');
    final small = MediaPreviews.shrink(source)!;
    expect(small.length, lessThanOrEqualTo(kPreviewMaxBytes));
    final decoded = img.decodeImage(small)!;
    expect(decoded.width <= kPreviewSide && decoded.height <= kPreviewSide, isTrue);
    expect(decoded.width, greaterThan(100), reason: 'still a picture');
    // Random noise is the worst case JPEG has: if the ladder handles this it
    // handles a photograph.
  });

  test('a portrait photograph keeps its shape', () {
    final small = MediaPreviews.shrink(_photo(900, 1600))!;
    expect(small.length, lessThanOrEqualTo(kPreviewMaxBytes));
    final decoded = img.decodeImage(small)!;
    expect(decoded.width, lessThan(decoded.height), reason: 'still a portrait');
    expect(decoded.height, lessThanOrEqualTo(kPreviewSide));
  });

  test('something that is not an image yields nothing, and does not throw', () {
    expect(MediaPreviews.shrink(Uint8List.fromList(List.filled(2000, 42))),
        isNull);
    expect(MediaPreviews.shrink(Uint8List(0)), isNull);
  });
}

/// The packet lane's cap, restated here so the test reads on its own.
const int kInlinePacketCapForTest = 32 * 1024;
