/// Tests for the encrypted profile storage backend + SecureProfileFile
/// (Phase 3 of docs/plan-encrypted-storage.md).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/profile/profile_crypto.dart';
import 'package:xprs/profile/profile_db.dart';
import 'package:xprs/profile/profile_storage_encrypted.dart';
import 'package:xprs/profile/secure_file.dart';

const _nsec =
    'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5';

void main() {

  late Directory tempRoot;
  late ProfileSecrets secrets;

  Future<EncryptedProfileStorage> encryptedStorage(String id) async {
    final dir = Directory('${tempRoot.path}/devices/$id')
      ..createSync(recursive: true);
    File('${dir.path}/$keyslotFileName').writeAsStringSync('{"version":1}');
    secrets = await ProfileCrypto.createProfileSecrets('pw 🔐', _nsec);
    ProfileKeyring.instance.putKeys(id, secrets.keys);
    return EncryptedProfileStorage(id, dir.path);
  }

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('enc_storage_test_');
    profileDbRootOverride = tempRoot.path;
  });

  tearDown(() async {
    await EncryptedProfileStorage.closeAllArchives();
    ProfileKeyring.instance.lockAll();
    profileDbRootOverride = null;
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('isPassthroughPath', () {
    test('routes correctly', () {
      // filesystem side
      expect(EncryptedProfileStorage.isPassthroughPath('keyslot.json'), isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('profile.zx'), isTrue);
      expect(
          EncryptedProfileStorage.isPassthroughPath('profile.zx-lock'), isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('.seeded.json'), isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('wapps/chat/app.wasm'),
          isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('data/mesh.zx'),
          isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('data/mesh.zx-lock'),
          isTrue);
      expect(
          EncryptedProfileStorage.isPassthroughPath('data/mesh.sqlite3'),
          isTrue);
      expect(
          EncryptedProfileStorage.isPassthroughPath(
              'data/chat/geochat.sqlite3-wal'),
          isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('data/rns_identity.key'),
          isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('data/folders.json'),
          isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('data/partials/x.part'),
          isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('data/share/abc.jpg'),
          isTrue);
      // archive side
      expect(EncryptedProfileStorage.isPassthroughPath('avatar.png'), isFalse);
      expect(EncryptedProfileStorage.isPassthroughPath('data/chat/kv.json'),
          isFalse);
      expect(
          EncryptedProfileStorage.isPassthroughPath('data/hal/notes.txt'),
          isFalse);
    });
  });

  group('EncryptedProfileStorage', () {
    test('loose file round-trip lands in archive, not on filesystem',
        () async {
      final st = await encryptedStorage('E1');

      await st.writeString('data/chat/kv.json', '{"hello":"🌍"}');
      expect(await st.readString('data/chat/kv.json'), equals('{"hello":"🌍"}'));
      expect(await st.exists('data/chat/kv.json'), isTrue);

      // Nothing plaintext on disk: only keyslot + profile.zx (+ its lock).
      final files = Directory('${tempRoot.path}/devices/E1')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.split('/').last)
          .toList();
      expect(files.where((f) => f.contains('kv.json')), isEmpty);
      expect(files.where((f) => f.startsWith('profile.zx')), isNotEmpty);

      // Content really is unreadable in the archive file.
      final ear =
          File('${tempRoot.path}/devices/E1/profile.zx').readAsBytesSync();
      expect(utf8.decode(ear, allowMalformed: true).contains('hello'), isFalse);
    });

    test('a big file copied in is stored in pieces and comes back whole',
        () async {
      final st = await encryptedStorage('E9');
      // 2.5 pieces of 256 KiB, a pattern that shows any misplaced byte
      final big = Uint8List.fromList(
          List<int>.generate(640 * 1024 + 7, (i) => (i * 31 + i ~/ 977) & 0xff));
      final src = File('${tempRoot.path}/outside/big.bin')
        ..createSync(recursive: true)
        ..writeAsBytesSync(big);

      await st.copyFromExternal(src.path, 'data/files/big.bin');
      expect(File('${tempRoot.path}/devices/E9/data/files/big.bin').existsSync(),
          isFalse);
      expect(await st.readBytes('data/files/big.bin'), equals(big));
      expect(st.readBytesSync('data/files/big.bin'), equals(big));

      final listed = (await st.listDirectory('data/files'))
          .singleWhere((e) => e.name == 'big.bin');
      expect(listed.size, big.length);

      final out = '${tempRoot.path}/outside/back.bin';
      await st.copyToExternal('data/files/big.bin', out);
      expect(File(out).readAsBytesSync(), equals(big));

      // overwritten by a small file, then deleted
      await st.writeString('data/files/big.bin', 'small');
      expect(await st.readString('data/files/big.bin'), 'small');
      await st.copyFromExternal(src.path, 'data/files/big.bin');
      await st.renameDirectory('data/files', 'data/moved');
      expect(await st.readBytes('data/moved/big.bin'), equals(big));
      await st.deleteDirectory('data/moved', recursive: true);
      expect(await st.exists('data/moved/big.bin'), isFalse);
      expect(await st.directoryExists('data/moved'), isFalse);
    });

    test('passthrough write creates a real file', () async {
      final st = await encryptedStorage('E2');
      await st.writeString('wapps/chat/manifest.json', '{"id":"chat"}');
      expect(
          File('${tempRoot.path}/devices/E2/wapps/chat/manifest.json')
              .existsSync(),
          isTrue);
    });

    test('json round-trip + appendString + delete', () async {
      final st = await encryptedStorage('E3');

      await st.writeJson('data/x/meta.json', {'a': 1});
      expect((await st.readJson('data/x/meta.json'))!['a'], equals(1));

      await st.appendString('data/x/log.txt', 'line1\n');
      await st.appendString('data/x/log.txt', 'line2\n');
      expect(await st.readString('data/x/log.txt'), equals('line1\nline2\n'));

      await st.delete('data/x/log.txt');
      expect(await st.exists('data/x/log.txt'), isFalse);
      // deleting again is a no-op like the fs backend
      await st.delete('data/x/log.txt');
    });

    test('listDirectory merges archive and filesystem entries', () async {
      final st = await encryptedStorage('E4');

      await st.writeString('data/w/kv.json', '{}'); // archive
      await st.writeBytes('data/w/blob.bin', Uint8List.fromList([1, 2, 3]));
      File('${tempRoot.path}/devices/E4/data/w/store.zx')
        ..createSync(recursive: true)
        ..writeAsStringSync('fake-db'); // filesystem

      final names = (await st.listDirectory('data/w')).map((e) => e.name).toSet();
      expect(names, containsAll({'kv.json', 'blob.bin', 'store.zx'}));

      // root listing hides the container + keyslot
      final rootNames =
          (await st.listDirectory('')).map((e) => e.name).toSet();
      expect(rootNames.contains('profile.zx'), isFalse);
      expect(rootNames.contains(keyslotFileName), isFalse);
    });

    test('directoryExists + renameDirectory across archive entries', () async {
      final st = await encryptedStorage('E5');
      await st.writeString('data/old/a.txt', 'A');
      await st.writeString('data/old/deep/b.txt', 'B');
      expect(await st.directoryExists('data/old'), isTrue);

      await st.renameDirectory('data/old', 'data/new');
      expect(await st.readString('data/new/a.txt'), equals('A'));
      expect(await st.readString('data/new/deep/b.txt'), equals('B'));
      expect(await st.directoryExists('data/old'), isFalse);
    });

    test('sync ops work after unlock pre-open', () async {
      final st = await encryptedStorage('E6');
      // onUnlock pre-open is fire-and-forget; force it deterministically
      // with one async op, as first boot does.
      await st.exists('data/anything');

      st.writeBytesSync('data/w/sync.bin', Uint8List.fromList([9, 8, 7]));
      expect(st.existsSync('data/w/sync.bin'), isTrue);
      expect(st.readBytesSync('data/w/sync.bin'), equals([9, 8, 7]));
      expect(await st.readBytes('data/w/sync.bin'), equals([9, 8, 7]));
    });

    test('data persists across archive close/reopen', () async {
      var st = await encryptedStorage('E7');
      await st.writeString('data/keep.txt', 'still here');
      await EncryptedProfileStorage.closeArchive('E7');

      st = EncryptedProfileStorage('E7', '${tempRoot.path}/devices/E7');
      expect(await st.readString('data/keep.txt'), equals('still here'));
    });

    test('locked profile throws ProfileLockedException', () async {
      final st = await encryptedStorage('E8');
      await st.writeString('data/x.txt', 'x');
      ProfileKeyring.instance.lock('E8');

      await expectLater(
        st.readString('data/x.txt'),
        throwsA(isA<ProfileLockedException>()),
      );
    });
  });

  group('SecureProfileFile', () {
    test('plain profile: passthrough plain bytes', () {
      final dir = Directory('${tempRoot.path}/devices/PLAIN/data')
        ..createSync(recursive: true);
      final path = '${dir.path}/rns_identity.key';
      SecureProfileFile.writeBytes(path, Uint8List.fromList([1, 2, 3, 4]));
      // Plain on disk (no AEF1 magic).
      expect(File(path).readAsBytesSync(), equals([1, 2, 3, 4]));
      expect(SecureProfileFile.readBytes(path), equals([1, 2, 3, 4]));
    });

    test('encrypted profile: wrapped on disk, round-trips', () async {
      await encryptedStorage('S1');
      final path = '${tempRoot.path}/devices/S1/data/rns_identity.key';
      final secret = Uint8List.fromList(List.generate(64, (i) => i));

      SecureProfileFile.writeBytes(path, secret);

      final raw = File(path).readAsBytesSync();
      expect(String.fromCharCodes(raw.sublist(0, 4)), equals('AEF1'));
      expect(raw, isNot(equals(secret)));

      expect(SecureProfileFile.readBytes(path), equals(secret));
    });

    test('pre-encryption plain file still readable in encrypted profile',
        () async {
      await encryptedStorage('S2');
      final path = '${tempRoot.path}/devices/S2/data/folders.json';
      File(path)
        ..createSync(recursive: true)
        ..writeAsStringSync('[{"folderId":"aa","priv":"bb"}]');

      expect(SecureProfileFile.readString(path),
          equals('[{"folderId":"aa","priv":"bb"}]'));

      // next write encrypts
      SecureProfileFile.writeString(path, '[]');
      final raw = File(path).readAsBytesSync();
      expect(String.fromCharCodes(raw.sublist(0, 4)), equals('AEF1'));
      expect(SecureProfileFile.readString(path), equals('[]'));
    });

    test('locked profile: reading a wrapped file throws', () async {
      await encryptedStorage('S3');
      final path = '${tempRoot.path}/devices/S3/data/rns_identity.key';
      SecureProfileFile.writeBytes(path, Uint8List.fromList([5, 5, 5]));
      ProfileKeyring.instance.lock('S3');

      expect(() => SecureProfileFile.readBytes(path), throwsA(anything));
    });
  });
}
