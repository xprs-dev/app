import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:xprs/services/media/media_preview.dart';

/// A noisy photograph is the worst case for JPEG, so it is what decides
/// whether a profile picture fits the packet lane (XPRS.md 6.3.2, 7.7.6).
Uint8List _noisy(int w, int h, {bool png = false}) {
  final r = Random(7);
  final im = img.Image(width: w, height: h);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      im.setPixelRgb(x, y, r.nextInt(256), r.nextInt(256), r.nextInt(256));
    }
  }
  return png ? img.encodePng(im) : img.encodeJpg(im, quality: 95);
}

void main() {
  test('a large noisy photograph becomes a small square JPEG', () {
    final out = MediaPreviews.avatarThumb(_noisy(1600, 1200))!;
    expect(out.length, lessThanOrEqualTo(kAvatarMaxBytes));
    final back = img.decodeJpg(out)!;
    expect(back.width, back.height, reason: 'square, centre-cropped');
    expect(kAvatarSides, contains(back.width));
  });

  test('a PNG portrait is cropped square too', () {
    final out = MediaPreviews.avatarThumb(_noisy(300, 500, png: true))!;
    final back = img.decodeJpg(out)!;
    expect(back.width, back.height);
    expect(out.length, lessThanOrEqualTo(kAvatarMaxBytes));
  });

  test('a picture smaller than the thumbnail is not blown up', () {
    final out = MediaPreviews.avatarThumb(_noisy(40, 40))!;
    expect(img.decodeJpg(out)!.width, 40);
  });

  test('garbage, empty and oversized input give no picture, and no throw', () {
    expect(MediaPreviews.avatarThumb(Uint8List(0)), isNull);
    expect(MediaPreviews.avatarThumb(Uint8List.fromList(List.filled(500, 7))),
        isNull);
    expect(MediaPreviews.avatarThumb(Uint8List(kPreviewSourceMax + 1)), isNull);
  });
}
