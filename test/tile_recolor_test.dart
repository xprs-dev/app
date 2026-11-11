import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xprs/wapp/geoui/tile_recolor.dart';

List<int> paint(int r, int g, int b) =>
    recolorDark(Uint8List.fromList([r, g, b, 255])).sublist(0, 4);

void main() {
  test('land goes to the Protomaps earth colour', () {
    expect(paint(0xf2, 0xef, 0xe9), [0x1f, 0x1f, 0x1f, 255]);
  });
  test('water goes to blue-grey', () {
    expect(paint(0xaa, 0xd3, 0xdf), [0x31, 0x35, 0x3f, 255]);
  });
  test('parks go dark green, roads lighter than land, text light', () {
    final park = paint(0xc8, 0xfa, 0xcc);
    expect(park[1] > park[0], isTrue);
    expect(paint(255, 255, 255)[0], greaterThan(0x1f));
    expect(paint(0x22, 0x22, 0x22)[0], greaterThan(140));
  });
  test('desert sand is not taken for a road', () {
    expect(paint(0xf5, 0xe9, 0xc6)[0], lessThan(0x30));
  });
  test('alpha is kept', () {
    expect(recolorDark(Uint8List.fromList([255, 255, 255, 0]))[3], 0);
  });
  test('style names', () {
    expect(isRecolorStyle('dark'), isTrue);
    expect(isRecolorStyle('mono'), isFalse);
  });
}
