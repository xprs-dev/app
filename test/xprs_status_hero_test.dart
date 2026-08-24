/// The launcher hero shows what the RADIO heard, not the public internet.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/services/hero/xprs_status_hero_source.dart';

void main() {
  test('the status body is everything after m:, colons and spaces included',
      () {
    const wire = 't:status f:X1G2QA ts:2026-08-24_17:51:04 sig:abc '
        'm:net control 19:30 on the hill: bring a handheld';

    expect(
      XprsStatusHeroSource.messageOf(wire),
      'net control 19:30 on the hill: bring a handheld',
    );
  });

  test('a packet with no message yields nothing to show', () {
    expect(XprsStatusHeroSource.messageOf('t:status f:X1G2QA ts:x'), isEmpty);
  });
}
