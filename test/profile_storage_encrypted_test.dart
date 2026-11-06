/// Tests for the encrypted profile storage backend + SecureProfileFile
/// (Phase 3 of docs/plan-encrypted-storage.md).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zx/zxdb.dart' show zxLooksPacked, zxUnpackBytes;

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
    await EncryptedProfileStorage.closeAllStores();
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
      expect(EncryptedProfileStorage.isPassthroughPath('profile.zx-lock'),
          isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('.seeded.json'), isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('wapps/chat/app.wasm'),
          isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('data/mesh.zx'), isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('data/mesh.zx-lock'),
          isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('data/media/abc'),
          isTrue);
      expect(
          EncryptedProfileStorage.isPassthroughPath(
              'data/chat/geochat.zx'),
          isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('data/rns_identity.key'),
          isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('data/folders.json'),
          isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('data/partials/x.part'),
          isTrue);
      expect(EncryptedProfileStorage.isPassthroughPath('data/share/abc.jpg'),
          isTrue);
      // profile.zx side
      expect(EncryptedProfileStorage.isPassthroughPath('avatar.png'), isFalse);
      expect(EncryptedProfileStorage.isPassthroughPath('data/chat/kv.json'),
          isFalse);
      expect(
          EncryptedProfileStorage.isPassthroughPath('data/hal/notes.txt'),
          isFalse);
    });
  });

  group('EncryptedProfileStorage', () {
    test('loose file round-trip lands in profile.zx, not on filesystem',
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

      // Content and names really are unreadable in the store's file.
      final store =
          File('${tempRoot.path}/devices/E1/profile.zx').readAsBytesSync();
      final text = utf8.decode(store, allowMalformed: true);
      expect(text.contains('hello'), isFalse);
      expect(text.contains('kv.json'), isFalse);
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

    test('listDirectory merges profile.zx and filesystem entries', () async {
      final st = await encryptedStorage('E4');

      await st.writeString('data/w/kv.json', '{}'); // profile.zx
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

    test('directoryExists + renameDirectory across profile.zx rows', () async {
      final st = await encryptedStorage('E5');
      await st.writeString('data/old/a.txt', 'A');
      await st.writeString('data/old/deep/b.txt', 'B');
      expect(await st.directoryExists('data/old'), isTrue);

      await st.renameDirectory('data/old', 'data/new');
      expect(await st.readString('data/new/a.txt'), equals('A'));
      expect(await st.readString('data/new/deep/b.txt'), equals('B'));
      expect(await st.directoryExists('data/old'), isFalse);
    });

    test('empty directories, recursive listing and deleteDirectory',
        () async {
      final st = await encryptedStorage('E9');
      await st.createDirectory('data/empty');
      expect(await st.directoryExists('data/empty'), isTrue);
      await st.writeString('data/t/a/b.txt', 'b');
      await st.writeString('data/t/c.txt', 'c');
      final flat = (await st.listDirectory('data/t')).map((e) => e.path).toSet();
      expect(flat, containsAll({'data/t/a', 'data/t/c.txt'}));
      expect(flat.contains('data/t/a/b.txt'), isFalse);
      final deep = (await st.listDirectory('data/t', recursive: true))
          .map((e) => e.path)
          .toSet();
      expect(deep, containsAll({'data/t/a', 'data/t/a/b.txt', 'data/t/c.txt'}));
      await st.deleteDirectory('data/t', recursive: true);
      expect(await st.exists('data/t/c.txt'), isFalse);
      expect(await st.directoryExists('data/t'), isFalse);
      final ext = '${tempRoot.path}/out/c.txt';
      await st.writeString('data/x.txt', 'external');
      await st.copyToExternal('data/x.txt', ext);
      expect(File(ext).readAsStringSync(), 'external');
      await st.copyFromExternal(ext, 'data/y.txt');
      expect(await st.readString('data/y.txt'), 'external');
    });

    test('sync ops work from the first call (no async open first)',
        () async {
      final st = await encryptedStorage('E6');
      st.writeBytesSync('data/w/sync.bin', Uint8List.fromList([9, 8, 7]));
      expect(st.existsSync('data/w/sync.bin'), isTrue);
      expect(st.readBytesSync('data/w/sync.bin'), equals([9, 8, 7]));
      expect(await st.readBytes('data/w/sync.bin'), equals([9, 8, 7]));
    });

    test('data persists across store close/reopen', () async {
      var st = await encryptedStorage('E7');
      await st.writeString('data/keep.txt', 'still here');
      await EncryptedProfileStorage.closeStore('E7');

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
      // Plain on disk (not packed).
      expect(File(path).readAsBytesSync(), equals([1, 2, 3, 4]));
      expect(SecureProfileFile.readBytes(path), equals([1, 2, 3, 4]));
    });

    test('encrypted profile: a packed, encrypted .zx on disk, round-trips', () async {
      await encryptedStorage('S1');
      final path = '${tempRoot.path}/devices/S1/data/rns_identity.key';
      final secret = Uint8List.fromList(List.generate(64, (i) => i));

      SecureProfileFile.writeBytes(path, secret);

      final raw = File(path).readAsBytesSync();
      expect(zxLooksPacked(raw), isTrue);
      expect(() => zxUnpackBytes(raw), throwsA(anything),
          reason: 'needs the password');

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
      expect(zxLooksPacked(raw), isTrue);
      expect(utf8.decode(raw, allowMalformed: true).contains('[]'), isFalse);
      expect(SecureProfileFile.readString(path), equals('[]'));
    });

    test('locked profile: reading a wrapped file throws', () async {
      await encryptedStorage('S3');
      final path = '${tempRoot.path}/devices/S3/data/rns_identity.key';
      SecureProfileFile.writeBytes(path, Uint8List.fromList([5, 5, 5]));
      ProfileKeyring.instance.lock('S3');

      expect(() => SecureProfileFile.readBytes(path), throwsA(anything));
    });

    test('a file packed for another profile key fails, not garbage',
        () async {
      await encryptedStorage('S4');
      final path = '${tempRoot.path}/devices/S4/data/rns_identity.key';
      SecureProfileFile.writeBytes(path, Uint8List.fromList([1, 2]));
      await encryptedStorage('S4'); // new secrets: another master key
      expect(() => SecureProfileFile.readBytes(path),
          throwsA(isA<SecureFileException>()));
    });
  });
}
