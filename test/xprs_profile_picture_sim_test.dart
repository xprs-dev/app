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
import 'package:xprs/services/xprs/xprs_groups.dart';
import 'package:xprs/services/xprs/xprs_id.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_profiles.dart';
import 'package:xprs/services/xprs/xprs_publisher.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/util/media_ref.dart';
import 'package:xprs/util/nostr_crypto.dart';

({BigInt d, Uint8List pub}) _key() {
  final kp = NostrCrypto.generateKeyPair();
  var d = BigInt.zero;
  for (final b in HEX.decode(kp.privateKeyHex)) {
    d = (d << 8) | BigInt.from(b);
  }
  return (d: d, pub: Uint8List.fromList(HEX.decode(kp.publicKeyHex)));
}

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

  // A group is a station (10.1): its picture is a decoration signed with the
  // GROUP's key. The group has no mailbox and holds no bytes, so a member
  // asks the stations its roster lists, the admin who made it first.
  test('a group picture: signed by the group, fetched from its members',
      () async {
    final grp = _key(), admin = _key();
    const gc = 'X5GULF', ac = 'X1ANNA';
    final keys = {gc: grp.pub, ac: admin.pub};
    final groups = XprsGroups.instance
      ..clear()
      ..keyResolver = (c) => keys[c];
    // The admin's own creation acts: a self-grant, then the acceptance.
    final grant = xprsSign(
        XprsPacket.parse(
            't:moderate f:$gc d:$gc ts:2026-10-06_10:00:00 grant:$ac')!,
        grp.d);
    groups.offer(grant);
    groups.offer(xprsSign(
        XprsPacket.parse('t:moderate f:$ac d:$gc ts:2026-10-06_10:00:01 '
            'r:${xprsIdentifier(grant)} accept:member')!,
        admin.d));

    final thumb = MediaPreviews.avatarThumb(
        img.encodeJpg(img.Image(width: 64, height: 64)))!;
    final token = _token(thumb);
    final wires = XprsPublisher.composeDecoration(
        call: gc, nick: 'Gulf-net', fileToken: token, about: '',
        ts: '2026-10-06_10:30:00', signingKey: grp.d);
    expect(wires, isNotEmpty);
    expect(XprsPacket.parse(wires.first)!['f'], gc);

    final b = XprsProfiles.instance;
    final held = <String, Uint8List>{};
    final askedOf = <String>[];
    b.keyResolver = (c) => keys[c];
    b.identityRows = (c) => const [];
    b.isKnown = null; // a group whose record we keep is known by default
    b.holdersFor = null; // and its holders come from its roster
    b.holds = held.containsKey;
    b.fetch = (ref, from) async {
      askedOf.add(from);
      if (from != ac) return false;
      held[ref.sha256] = thumb;
      return true;
    };
    for (final w in wires) {
      b.offer(gc, XprsPacket.parse(w)!);
    }
    for (var i = 0; i < 4; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(b.nickFor(gc), 'Gulf-net');
    expect(b.pictureFor(gc)?.token, token);
    expect(askedOf, [ac], reason: 'asked of the member, never of the X5');
    expect(held[MediaRef.parse(token)!.sha256], thumb);

    // A decoration signed by somebody else is not the group's.
    final forged = XprsPublisher.composeDecoration(
        call: gc, nick: 'Taken', fileToken: '', about: '',
        ts: '2026-10-07_10:30:00', signingKey: admin.d);
    for (final w in forged) {
      b.offer(gc, XprsPacket.parse(w)!);
    }
    expect(b.nickFor(gc), 'Gulf-net');
    expect(b.pictureFor(gc)?.token, token);
    groups.clear();
  });
}
