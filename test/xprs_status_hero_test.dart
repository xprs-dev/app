/// The launcher hero shows what the NETWORK is saying, not the public
/// internet — ranked by popularity until the user has chosen whose news
/// matters, and by that choice afterwards.
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

  test('a like counts once per station, and an unlike takes it back', () {
    final counts = XprsStatusHeroSource.debugLikeCounts([
      {'from': 'X1AAAA', 'wire': 't:reaction f:X1AAAA r:399227 add:like'},
      // the same station liking twice is still one like
      {'from': 'X1AAAA', 'wire': 't:reaction f:X1AAAA r:399227 add:like'},
      {'from': 'X1BBBB', 'wire': 't:reaction f:X1BBBB r:399227 add:like'},
      {'from': 'X1CCCC', 'wire': 't:reaction f:X1CCCC r:399227 add:like'},
      {'from': 'X1CCCC', 'wire': 't:reaction f:X1CCCC r:399227 remove:like'},
      {'from': 'X1DDDD', 'wire': 't:reaction f:X1DDDD r:555111 add:like'},
    ]);

    expect(counts['399227'], 2, reason: 'two stations still like it');
    expect(counts['555111'], 1);
  });

  test('a body containing m: does not confuse the field reader', () {
    final counts = XprsStatusHeroSource.debugLikeCounts([
      {'from': 'X1AAAA', 'wire': 't:reaction f:X1AAAA r:abc add:like m:r:zzz'},
    ]);

    expect(counts.keys.single, 'abc');
  });
}
