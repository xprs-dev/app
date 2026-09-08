// The core file-fetch entry point: the lane it chooses by size and
// reachability, that a file already held is re-used with no wire, and that a
// second ask for the same file joins the first rather than starting a
// duplicate. The lane policy (decide) is pure and tested on its own.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/services/media/media_fetch.dart';
import 'package:xprs/util/media_archive.dart';
import 'package:xprs/util/media_ref.dart';

void main() {
  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });

  const kb = 1024;
  const packetCap = 32 * 1024;

  group('decide: the lane by size and reachability', () {
    test('packet-lane sized (or unknown) always takes the packet lane', () {
      for (final tapped in [false, true]) {
        expect(
            MediaFetch.decide(
                size: 4 * kb, link: false, bleOnly: true, maxMb: 10, userTapped: tapped),
            MediaLane.packet);
        expect(
            MediaFetch.decide(
                size: null, link: false, bleOnly: false, maxMb: 0, userTapped: tapped),
            MediaLane.packet);
      }
    });

    test('a big file over a link, within the ceiling, takes bulk + internet', () {
      expect(
          MediaFetch.decide(
              size: 3 * 1024 * kb, link: true, bleOnly: false, maxMb: 10, userTapped: false),
          MediaLane.bulkAndInternet);
    });

    test('a big file reachable only over a shared radio WAITS for a tap', () {
      expect(
          MediaFetch.decide(
              size: 3 * 1024 * kb, link: false, bleOnly: true, maxMb: 10, userTapped: false),
          MediaLane.wait,
          reason: '10 MB over BLE jams the channel — never unasked');
      // Tapped, it goes (internet-only, since bleOnly means no usable link).
      expect(
          MediaFetch.decide(
              size: 3 * 1024 * kb, link: false, bleOnly: true, maxMb: 10, userTapped: true),
          MediaLane.internetOnly);
    });

    test('over the ceiling waits unless tapped', () {
      expect(
          MediaFetch.decide(
              size: 50 * 1024 * kb, link: true, bleOnly: false, maxMb: 10, userTapped: false),
          MediaLane.wait);
      expect(
          MediaFetch.decide(
              size: 50 * 1024 * kb, link: true, bleOnly: false, maxMb: 10, userTapped: true),
          MediaLane.bulkAndInternet);
    });

    test('auto-download off (maxMb 0): a big file waits, tap sends it', () {
      expect(
          MediaFetch.decide(
              size: 100 * kb, link: true, bleOnly: false, maxMb: 0, userTapped: false),
          MediaLane.wait);
      expect(
          MediaFetch.decide(
              size: 100 * kb, link: true, bleOnly: false, maxMb: 0, userTapped: true),
          MediaLane.bulkAndInternet);
    });

    test('the packet-lane cap is the real threshold', () {
      expect(
          MediaFetch.decide(
              size: packetCap, link: false, bleOnly: false, maxMb: 10, userTapped: false),
          MediaLane.packet);
      expect(
          MediaFetch.decide(
              size: packetCap + 1, link: false, bleOnly: false, maxMb: 10, userTapped: false),
          MediaLane.internetOnly);
    });
  });

  group('want: re-use and dedup', () {
    late Directory dir;
    late MediaArchive archive;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('media_fetch_test_');
      archive = MediaArchive.forDirectory(dir.path);
      MediaFetch.instance.archive = (() => archive);
      MediaFetch.instance.selfCallsign = (() => 'X1SELF');
      MediaFetch.instance.internetResolve = null; // no lane runs in this test
      archive.onPut = MediaFetch.instance.notePut;
    });

    tearDown(() {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('a file already held resolves at once, no lane', () async {
      final token = archive.putBytes(Uint8List.fromList([1, 2, 3]), 'bin');
      final ref = MediaRef.parse(token)!;
      final before = MediaFetch.instance.served;
      expect(await MediaFetch.instance.want(ref), isTrue);
      expect(MediaFetch.instance.served, before + 1);
      expect(MediaFetch.instance.progress(ref.sha256).state, MediaState.ready);
    });

    test('onPut completes a waiter — the bytes landing is the completion',
        () async {
      // A packet-lane want with no reachable holder still opens a waiter; the
      // archive receiving the bytes (any lane) is what completes it.
      final bytes = Uint8List.fromList(List.generate(500, (i) => i % 256));
      // Compute the ref the bytes will have without storing them yet.
      final token = MediaArchive.forDirectory(
              Directory.systemTemp.createTempSync('probe_').path)
          .putBytes(bytes, 'png');
      final ref = MediaRef.parse(token)!;

      final want = MediaFetch.instance.want(ref, from: 'X1PEER', size: 500);
      // Same ref again → the same future, not a second attempt.
      expect(identical(want, MediaFetch.instance.want(ref, from: 'X1PEER')), isTrue,
          reason: 'one in-flight per sha');
      // The bytes arrive by whatever lane → onPut → the waiter completes true.
      archive.putBytes(bytes, 'png');
      expect(await want, isTrue);
      expect(MediaFetch.instance.progress(ref.sha256).state, MediaState.ready);
    });
  });
}
