/*
 * A folder as the format publishes it (XPRS.md 7.7.2, 7.7.3): the listing
 * is deterministic, a reader gets back exactly what was listed, the two
 * descriptions fit and verify, and a publish stores, holds, airs and
 * deposits -- with no store, no radio and no clock.
 */
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';
import 'package:xprs/services/xprs/xprs_folder.dart';
import 'package:xprs/services/xprs/xprs_packet.dart';
import 'package:xprs/services/xprs/xprs_sig.dart';
import 'package:xprs/services/xprs/xprs_vocab.dart';
import 'package:xprs/util/nostr_crypto.dart';

String _sha(String s) => crypto.sha256.convert(utf8.encode(s)).toString();

void main() {
  final pair = NostrCrypto.generateKeyPair();
  final key = BigInt.parse(pair.privateKeyHex, radix: 16);
  final pub = Uint8List.fromList(
      HEX.decode(NostrCrypto.derivePublicKey(pair.privateKeyHex)));

  final tdeck = XprsFolderEntry(shaHex: _sha('tdeck'), size: 1460192, name: 'tdeck-0.5.1.bin');
  final c3 = XprsFolderEntry(shaHex: _sha('c3'), size: 1310720, name: 'esp32c3-mini-0.2.1.bin');
  final notes = XprsFolderEntry(shaHex: _sha('notes'), size: 812, name: 'release notes.txt');

  group('the listing (7.7.2)', () {
    test('XFL1, ref size name, sorted bytewise by name, LF terminated', () {
      final l = xprsListingBuild([tdeck, notes, c3]);
      final lines = l.split('\n');
      expect(lines.first, 'XFL1');
      expect(lines[1], startsWith('${c3.ref} 1310720 esp32c3-mini-0.2.1.bin'));
      expect(lines[2], '${notes.ref} 812 release notes.txt');
      expect(lines[3], '${tdeck.ref} 1460192 tdeck-0.5.1.bin');
      expect(l, endsWith('\n'));
      expect(xprsListingBuild([notes, c3, tdeck]), l, reason: 'order in, same bytes out');
    });

    test('a reference is 43 base64url characters and the type', () {
      expect(tdeck.ref, matches(RegExp(r'^[A-Za-z0-9_-]{43}\.bin$')));
      expect(xprsFileShaOf(tdeck.ref), tdeck.shaHex);
      expect(xprsFileShaOf(tdeck.shaHex), tdeck.shaHex, reason: 'the older hex form reads the same');
      expect(xprsFileShaOf('not a ref'), isNull);
    });

    test('reading back gives what was listed; a bad line is skipped', () {
      final l = xprsListingBuild([tdeck, notes, c3]) + 'garbage line\nX 12\n';
      final back = xprsListingParse(l)!;
      expect(back.map((e) => e.name), ['esp32c3-mini-0.2.1.bin', 'release notes.txt', 'tdeck-0.5.1.bin']);
      expect(back[2].shaHex, tdeck.shaHex);
      expect(back[2].size, 1460192);
      expect(xprsListingParse('XFL2\n'), isNull);
    });

    test('sizes read as qty: bare bytes, kB, MB', () {
      expect(xprsBytesOf('812'), 812);
      expect(xprsBytesOf('240kB'), 240 * 1024);
      expect(xprsBytesOf('2MB'), 2 * 1024 * 1024);
      expect(xprsBytesOf('x'), 0);
    });
  });

  group('the descriptions (7.7.1, 7.7.3)', () {
    const ts = '2026-10-25_12:00:00';
    test('a member: file, size, name, signed, inside the packet', () {
      final p = xprsDescribeMember(self: 'X1PUB1', entry: tdeck, ts: ts, key: key)!;
      expect(p.type, 'file');
      expect(p['file'], tdeck.ref);
      expect(p['size'], '1460192');
      expect(p['name'], 'tdeck-0.5.1.bin');
      expect(p.fits, isTrue);
      expect(xprsVerify(p, pub), XprsSigState.verified);
      final n = xprsDescribeMember(self: 'X1PUB1', entry: notes, ts: ts, key: key)!;
      expect(n['name'], 'release_notes.txt', reason: 'a value carries no space');
    });

    test('the folder: the listing reference with kind:folder, count, size, name', () {
      final p = xprsDescribeFolder(
          self: 'X1PUB1', listingShaHex: _sha('listing'), count: 3,
          totalSize: 1460192 + 1310720 + 812, name: 'XPRS firmware stable',
          ts: ts, key: key)!;
      expect(p['kind'], 'folder');
      expect(p['count'], '3');
      expect(p['file'], endsWith('.xfl'));
      expect(p['m'], 'XPRS firmware stable');
      expect(xprsVerify(p, pub), XprsSigState.verified);
      expect(xprsFolderListingSha(p), _sha('listing'));
      expect(xprsFolderListingSha(xprsDescribeMember(self: 'X1PUB1', entry: tdeck, ts: ts)!), isNull);
    });
  });

  group('publishing', () {
    test('stores and holds the listing, airs and deposits every description', () async {
      final stored = <String, Uint8List>{};
      final aired = <String>[];
      List<String>? deposited;
      final pubr = XprsFolderPublisher(
        self: 'X1PUB1',
        key: key,
        now: () => DateTime.utc(2026, 10, 25, 12),
        store: (bytes, ext, name) {
          final sha = crypto.sha256.convert(bytes).toString();
          stored['$sha.$ext|$name'] = bytes;
          return sha;
        },
        air: (w) async => aired.add(w),
        deposit: (ws) => deposited = ws,
      );
      final sha = await pubr.publish('XPRS firmware stable', [tdeck, c3, notes]);
      expect(sha, isNotNull);
      expect(stored.keys.single, '$sha.xfl|XPRS_firmware_stable.xfl');
      expect(utf8.decode(stored.values.single), startsWith('XFL1\n'));
      expect(aired, hasLength(4), reason: 'the folder and three members');
      expect(deposited, aired);
      final folder = XprsPacket.parse(aired.first)!;
      expect(folder['kind'], 'folder');
      expect(folder['ts'], '2026-10-25_12:00:00');
      expect(xprsFolderListingSha(folder), sha);
      expect(xprsParseTs(folder['ts']), isNotNull);
    });

    test('no key, no folder: an unsigned publication is nobody\'s', () async {
      var aired = 0;
      final pubr = XprsFolderPublisher(
          self: 'X1PUB1', store: (b, e, n) => 'x', air: (w) async => aired++, deposit: (_) {});
      expect(await pubr.publish('x', [tdeck]), isNull);
      expect(aired, 0);
    });
  });
}
