// Two stations, one picture, end to end at the core: A makes its picture the
// way the profile editor does (a square thumbnail, content-addressed), says it
// in a signed decoration; B hears it through the receive seam, holds A's key,
// keeps the decoration, fetches the bytes through the one fetch door it has,
// and ends up with exactly A's bytes. Then A takes the picture back.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';
import 'package:image/image.dart' as img;
import 'package:xprs/services/media/media_preview.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_profiles.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:xprs/util/media_ref.dart';
import 'package:xprs/util/nostr_crypto.dart';

String _token(Uint8List b) {
  final sha = base64Url.encode(sha256.convert(b).bytes).replaceAll('=', '');
  return 'file:$sha.jpg';
}

void main() {
  test('A sets a picture, B sees it, A removes it, B lets it go', () async {
    // Station A: a key and a photograph.
    final kp = NostrCrypto.generateKeyPair();
    var d = BigInt.zero;
    for (final b in HEX.decode(kp.privateKeyHex)) {
      d = (d << 8) | BigInt.from(b);
    }
    final pubA = Uint8List.fromList(HEX.decode(kp.publicKeyHex));
    final r = Random(3);
    final photo = img.Image(width: 900, height: 600);
    for (var y = 0; y < 600; y += 3) {
      for (var x = 0; x < 900; x += 3) {
        img.fillRect(photo, x1: x, y1: y, x2: x + 3, y2: y + 3,
            color: img.ColorRgb8(r.nextInt(256), 120, r.nextInt(256)));
      }
    }
    final thumb = MediaPreviews.avatarThumb(img.encodeJpg(photo))!;
    final tokenA = _token(thumb);
    final archiveA = {MediaRef.parse(tokenA)!.sha256: thumb};

    // What A airs.
    final wires = XprsPublisher.composeDecoration(
        call: 'X16JK8', nick: 'Brito', fileToken: tokenA,
        about: 'on the bench', ts: '2026-10-06_10:30:00', signingKey: d);
    expect(wires, isNotEmpty);

    // Station B: knows A's key (the binding is heard every 30 minutes), and
    // fetches by copying from A's store, as cmd:file would.
    final b = XprsProfiles.instance;
    final archiveB = <String, Uint8List>{};
    b.keyResolver = (c) => c == 'X16JK8' ? pubA : null;
    b.identityRows = (c) => const [];
    b.isKnown = (c) => true; // a correspondent
    b.holds = archiveB.containsKey;
    b.fetch = (ref, from) async {
      expect(from, 'X16JK8');
      final bytes = archiveA[ref.sha256];
      if (bytes == null) return false;
      archiveB[ref.sha256] = bytes;
      return true;
    };
    final ticks = b.revision.value;
    for (final w in wires) {
      b.offer('X16JK8', XprsPacket.parse(w)!);
    }
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(b.nickFor('X16JK8'), 'Brito');
    expect(b.aboutFor('X16JK8'), 'on the bench');
    final ref = b.pictureFor('X16JK8')!;
    expect(ref.token, tokenA);
    expect(archiveB[ref.sha256], thumb, reason: "B holds exactly A's bytes");
    expect(b.revision.value, greaterThan(ticks),
        reason: 'screens are told when the picture lands');

    // A removes the picture: file:-, newer.
    final gone = XprsPublisher.composeDecoration(
        call: 'X16JK8', nick: 'Brito', fileToken: '', about: 'on the bench',
        ts: '2026-10-07_09:00:00', signingKey: d);
    for (final w in gone) {
      b.offer('X16JK8', XprsPacket.parse(w)!);
    }
    expect(b.pictureFor('X16JK8'), isNull);
  });
}
