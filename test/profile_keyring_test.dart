/// The path -> (profile, relative path) mapping every store secret is built
/// on (core profile_keyring.dart). The stores' encryption itself (plain,
/// encrypted, locked, wrong key) is tested in core's store_db_test.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:xprs/profile/profile_keyring.dart';

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('profile_keyring_test_');
    profileDbRootOverride = tempRoot.path;
  });

  tearDown(() {
    profileDbRootOverride = null;
    ProfileKeyring.instance.lockAll();
    try {
      tempRoot.deleteSync(recursive: true);
    } catch (_) {}
  });

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
}
