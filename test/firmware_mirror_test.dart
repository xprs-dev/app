/*
 * The firmware mirror: the document is believed only through the
 * publisher's signatures, a tick fetches what is missing and verifies it,
 * keeps the newest set, offers it, and relays the descriptions verbatim.
 * No network, no device: every effect injected.
 */
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:hex/hex.dart';
import 'package:xprs/services/firmware_mirror_service.dart';
import 'package:xprs/services/xprs/xprs_folder.dart';
import 'package:xprs/util/nostr_crypto.dart';

void main() {
  final pair = NostrCrypto.generateKeyPair();
  final key = BigInt.parse(pair.privateKeyHex, radix: 16);
  final pubHex = NostrCrypto.derivePublicKey(pair.privateKeyHex);
  final other = NostrCrypto.generateKeyPair();
  final otherKey = BigInt.parse(other.privateKeyHex, radix: 16);

  final img = Uint8List.fromList(List.generate(5000, (i) => (i * 7) & 0xff));
  final imgSha = crypto.sha256.convert(img).toString();
  final tdeck = XprsFolderEntry(shaHex: imgSha, size: img.length, name: 'tdeck-0.5.2.bin');
  final c3 = XprsFolderEntry(shaHex: 'ab' * 32, size: 1234, name: 'esp32c3-mini-0.2.2.bin');
  const ts = '2026-10-25_12:00:00';

  Map<String, dynamic> doc({BigInt? signer}) => {
        'generated': '2026-10-25T12:00:00Z',
        'stable': {
          'listing': 'cd' * 32,
          'wires': [
            xprsDescribeFolder(self: 'X1WATT', listingShaHex: 'cd' * 32, count: 2,
                    totalSize: 6234, name: 'XPRS firmware stable', ts: ts, key: signer ?? key)!
                .encode(),
            xprsDescribeMember(self: 'X1WATT', entry: tdeck, ts: ts, key: signer ?? key, tag: 'stable')!.encode(),
            xprsDescribeMember(self: 'X1WATT', entry: c3, ts: ts, key: signer ?? key, tag: 'stable')!.encode(),
          ],
          'members': [
            {'name': 'tdeck-0.5.2.bin', 'sha256': imgSha, 'size': img.length, 'url': 'https://x/tdeck.bin'},
            {'name': 'esp32c3-mini-0.2.2.bin', 'sha256': 'ab' * 32, 'size': 1234, 'url': 'https://x/c3.bin'},
            {'name': 'ghost-1.0.0.bin', 'sha256': 'ef' * 32, 'size': 9, 'url': 'https://x/ghost.bin'},
          ],
        },
      };

  group('reading the document', () {
    final pub = Uint8List.fromList(HEX.decode(pubHex));
    test('only what the publisher signed is believed', () {
      final f = FirmwareFeed.parse(doc(), pub);
      expect(f.channels.single.name, 'stable');
      expect(f.channels.single.wires, hasLength(3));
      expect(f.channels.single.members.map((m) => m.name), ['tdeck-0.5.2.bin', 'esp32c3-mini-0.2.2.bin']);
      expect(f.dropped, 1, reason: 'the member with no signed description');
    });

    test('another key, nothing', () {
      final f = FirmwareFeed.parse(doc(signer: otherKey), pub);
      expect(f.channels, isEmpty);
      expect(f.dropped, greaterThanOrEqualTo(3));
    });

    test('a member whose size disagrees with its description is refused', () {
      final d = doc();
      (d['stable']['members'] as List)[0]['size'] = 1;
      final f = FirmwareFeed.parse(d, pub);
      expect(f.channels.single.members.map((m) => m.name), ['esp32c3-mini-0.2.2.bin']);
    });
  });

  group('a tick', () {
    late Directory tmp;
    late FirmwareMirrorService svc;
    final downloads = <String>[];
    final heldNames = <String>[];
    final aired = <String>[];
    List<String>? deposited;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fwmirror');
      downloads.clear();
      heldNames.clear();
      aired.clear();
      deposited = null;
      svc = FirmwareMirrorService.instance
        ..publisherKeyHex = pubHex
        ..fetchText = ((url) async => jsonEncode(doc()))
        ..dirOf = (() async => tmp.path)
        ..hashFile = ((p) async => crypto.sha256.convert(File(p).readAsBytesSync()).toString())
        ..download = ((url, path) async {
          downloads.add(url);
          if (url.endsWith('tdeck.bin')) {
            File(path).writeAsBytesSync(img);
            return true;
          }
          File(path).writeAsBytesSync(utf8.encode('not the image'));
          return true;
        })
        ..hold = ((m, p) => heldNames.add(m.name))
        ..air = ((w) async => aired.add(w))
        ..deposit = ((ws) => deposited = ws);
      svc.held.clear();
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('fetches, verifies, keeps the good one, refuses the bad one, relays', () async {
      File('${tmp.path}/tdeck-0.5.1.bin').writeAsStringSync('old');
      await svc.tick();
      expect(downloads, hasLength(2));
      expect(File('${tmp.path}/tdeck-0.5.2.bin').readAsBytesSync(), img);
      expect(File('${tmp.path}/esp32c3-mini-0.2.2.bin').existsSync(), isFalse, reason: 'digest mismatch is not kept');
      expect(File('${tmp.path}/tdeck-0.5.1.bin').existsSync(), isFalse, reason: 'an older image is pruned');
      expect(heldNames, ['tdeck-0.5.2.bin']);
      expect(aired, hasLength(3), reason: 'the folder and both members, verbatim');
      expect(deposited, aired);
      expect(svc.statusJson()['held'], {'tdeck-0.5.2.bin': imgSha});
    });

    test('a second tick downloads nothing it already holds', () async {
      await svc.tick();
      downloads.clear();
      await svc.tick();
      expect(downloads, ['https://x/c3.bin'], reason: 'only the one still missing');
    });
  });
}
