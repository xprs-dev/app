// assets/wapps/ goes into EVERY build, the APK included. A native executable
// in there can never run on a phone, costs megabytes per install, and is a
// prebuilt binary F-Droid rejects outright. Desktop-only builds of a wapp
// belong in desktop/wapps/, which only the Linux and Windows bundles install.
// See docs/f-droid.md.

import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

/// ELF, PE ("MZ") and the four Mach-O magics.
bool _isNativeExecutable(Uint8List b) {
  if (b.length < 4) return false;
  if (b[0] == 0x7f && b[1] == 0x45 && b[2] == 0x4c && b[3] == 0x46) return true;
  if (b[0] == 0x4d && b[1] == 0x5a) return true;
  const machO = [
    [0xfe, 0xed, 0xfa, 0xce], [0xfe, 0xed, 0xfa, 0xcf],
    [0xce, 0xfa, 0xed, 0xfe], [0xcf, 0xfa, 0xed, 0xfe],
  ];
  return machO.any((m) => b[0] == m[0] && b[1] == m[1] && b[2] == m[2] && b[3] == m[3]);
}

void main() {
  final wapps = Directory('assets/wapps')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.wapp'))
      .toList();

  test('assets/wapps is not empty', () => expect(wapps, isNotEmpty));

  for (final wapp in wapps) {
    test('${wapp.path} carries no native executable', () {
      final zip = ZipDecoder().decodeBytes(wapp.readAsBytesSync());
      final offenders = <String>[
        for (final f in zip.files)
          if (f.isFile &&
              (f.name.startsWith('bin/') ||
                  _isNativeExecutable(f.content as Uint8List)))
            f.name,
      ];
      expect(offenders, isEmpty,
          reason: 'move the full build to desktop/wapps/ and bundle a copy '
              'without these in assets/wapps/');
    });
  }
}
