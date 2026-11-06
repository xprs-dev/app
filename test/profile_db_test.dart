/// Tests for the central profile database opener (Phase 2 of
/// docs/plan-encrypted-storage.md).
///
/// Every database is a zxdb file (pure Dart): the keyed paths run here as
/// they run in the app, with no native library to provide.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reticulum/reticulum.dart' show XDbException;

import 'package:xprs/profile/profile_crypto.dart';
import 'package:xprs/profile/profile_db.dart';

const _nsec =
    'nsec1vl029mgpspedva04g90vltkh6fvh240zqtv9k0t9af8935ke9laqsnlfe5';

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('profile_db_test_');
    profileDbRootOverride = tempRoot.path;
  });

  tearDown(() {
    profileDbRootOverride = null;
    ProfileKeyring.instance.lockAll();
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

  String profileDir(String id) => '${tempRoot.path}/devices/$id';

  group('locateProfileDb', () {
    test('maps devices/<id>/... paths', () {
      final loc =
          locateProfileDb('${tempRoot.path}/devices/X1ABCD/data/mesh.zx');
      expect(loc, isNotNull);
      expect(loc!.profileId, equals('X1ABCD'));
      expect(loc.relPath, equals('data/mesh.zx'));
    });

    test('maps nested wapp paths', () {
      final loc = locateProfileDb(
          '${tempRoot.path}/devices/X1ABCD/wapps/social/social.zx');
      expect(loc!.relPath, equals('wapps/social/social.zx'));
    });

    test('null for paths outside the storage root', () {
      expect(locateProfileDb('/somewhere/else/db.zx'), isNull);
      expect(locateProfileDb('${tempRoot.path}/profiles.json'), isNull);
      expect(locateProfileDb(':memory:'), isNull);
    });

    test('null for the profile dir itself', () {
      expect(locateProfileDb('${tempRoot.path}/devices/X1ABCD'), isNull);
      expect(locateProfileDb('${tempRoot.path}/devices/X1ABCD/'), isNull);
    });
  });

  group('plain profiles', () {
    test('openProfileDb opens a plain database (no keyslot)', () {
      final dir = Directory('${profileDir('PLAIN1')}/data')
        ..createSync(recursive: true);
      final path = '${dir.path}/test.zx';

      final db = openProfileDb(path);
      db.execute('CREATE TABLE t(v TEXT);');
      db.execute("INSERT INTO t VALUES ('hello');");
      db.dispose();

      // Opens again without any password.
      final again = openProfileDb(path);
      expect(again.select('SELECT v FROM t').first['v'], equals('hello'));
      again.dispose();
    });
  });

  group('encrypted profiles', () {
    late ProfileSecrets secrets;

    Future<void> enableEncryption(String profileId) async {
      secrets = await ProfileCrypto.createProfileSecrets('pw 🐘', _nsec);
      final dir = Directory(profileDir(profileId))..createSync(recursive: true);
      File('${dir.path}/$keyslotFileName')
          .writeAsStringSync('{"version":1}'); // presence marks encrypted
      ProfileKeyring.instance.putKeys(profileId, secrets.keys);
    }

    test('locked profile throws ProfileLockedException', () async {
      await enableEncryption('ENC1');
      ProfileKeyring.instance.lock('ENC1');

      expect(
        () => openProfileDb('${profileDir('ENC1')}/data/x.zx'),
        throwsA(isA<ProfileLockedException>()),
      );
    });

    test('keyed round-trip: write, reopen, read; the file holds no plaintext',
        () async {
      await enableEncryption('ENC2');
      final path = '${profileDir('ENC2')}/data/enc.zx';
      Directory('${profileDir('ENC2')}/data').createSync(recursive: true);

      final db = openProfileDb(path);
      db.execute('CREATE TABLE t(v TEXT);');
      db.execute("INSERT INTO t VALUES ('secret payload');");
      db.dispose();

      // The payload must not be readable in the file.
      final raw = String.fromCharCodes(File(path).readAsBytesSync());
      expect(raw.contains('secret payload'), isFalse);
      expect(raw.contains('CREATE TABLE'), isFalse);

      final again = openProfileDb(path);
      expect(again.select('SELECT v FROM t').first['v'],
          equals('secret payload'));
      again.dispose();
    });

    test('wrong profile keys fail to open the database', () async {
      await enableEncryption('ENC3');
      final path = '${profileDir('ENC3')}/data/enc.zx';
      Directory('${profileDir('ENC3')}/data').createSync(recursive: true);

      final db = openProfileDb(path);
      db.execute('CREATE TABLE t(v TEXT);');
      db.dispose();

      // Swap in keys derived from a different identity.
      final other = await ProfileCrypto.createProfileSecrets(
        'pw 🐘',
        'nsec1w7p0nsc7full96psqy5xnzeus4dl0z9cdvxg0dh9k75g0jfzyv2q08cwuz',
      );
      ProfileKeyring.instance.putKeys('ENC3', other.keys);

      expect(
        () => openProfileDb(path),
        throwsA(isA<XDbException>()),
      );
    });

    test('sibling databases get distinct keys but both open', () async {
      await enableEncryption('ENC4');
      Directory('${profileDir('ENC4')}/data').createSync(recursive: true);
      final a = '${profileDir('ENC4')}/data/a.zx';
      final b = '${profileDir('ENC4')}/data/b.zx';

      for (final path in [a, b]) {
        final db = openProfileDb(path);
        db.execute('CREATE TABLE t(v TEXT);');
        db.execute("INSERT INTO t VALUES ('$path');");
        db.dispose();
      }
      for (final path in [a, b]) {
        final db = openProfileDb(path);
        expect(db.select('SELECT v FROM t').first['v'], equals(path));
        db.dispose();
      }
      expect(secrets.keys.dbKeyHex('data/a.zx'),
          isNot(equals(secrets.keys.dbKeyHex('data/b.zx'))));
    });
  });
}
