/// Seed the desktop app's profile store with the firmware publisher identity,
/// headlessly, on the machine that runs firmware releases
/// (firmware/docs/plan-firmware-folders.md). The app itself only offers this
/// on its first-run screen, which a build box without a display cannot show.
///
/// NOT an automated test. Run it once, with the key in the environment and
/// HOME pointing at the account the app runs under:
///
///   XPRS_PUBLISHER_NSEC=nsec1... AURORA_TEST_HOME=1 \
///     flutter test tool/seed_publisher_profile_test.dart
///
/// It writes the same files the app's welcome page writes
/// (ProfileService.buildFromNsec + saveAndActivate), under
/// $HOME/.local/share/xprs, with the device-key encryption the app applies
/// to a new profile. The nsec never touches this repository.
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/open.dart';
import 'package:xprs/profile/profile_service.dart';
import 'package:xprs/profile/storage_paths.dart';

void main() {
  final nsec = Platform.environment['XPRS_PUBLISHER_NSEC'] ?? '';
  final armed = Platform.environment['AURORA_TEST_HOME'] == '1' && nsec.isNotEmpty;

  setUpAll(() {
    if (Platform.isLinux) {
      open.overrideFor(
          OperatingSystem.linux, () => DynamicLibrary.open('libsqlite3.so.0'));
    }
  });

  test('the publisher identity is in the store and active', () async {
    await initStorageRoot();
    final service = ProfileService.instance;
    await service.load();
    final profile = service.buildFromNsec(nsec, nickname: 'XPRS firmware publisher');
    final existing = service.profiles.where((p) => p.npub == profile.npub).toList();
    if (existing.isNotEmpty) {
      await service.switchTo(existing.first.id);
    } else {
      await service.saveAndActivate(profile,
          encrypt: Platform.environment['XPRS_PUBLISHER_PLAIN'] != '1');
    }
    final active = service.activeProfile!;
    expect(active.npub, profile.npub);
    // Printed so the caller can check it against fw_publisher.h.
    // ignore: avoid_print
    print('publisher profile: ${active.callsign} ${active.npub} (${active.id})');
  }, skip: armed ? false : 'set XPRS_PUBLISHER_NSEC and AURORA_TEST_HOME=1');
}
