library;

import 'dart:ffi' show Abi;

String? nativeBinaryKey() {
  final abi = Abi.current();
  return switch (abi) {
    Abi.linuxX64 => 'linux-x86_64',
    Abi.linuxArm64 => 'linux-arm64',
    Abi.windowsX64 => 'windows-x86_64',
    Abi.windowsArm64 => 'windows-arm64',
    Abi.macosX64 => 'macos-x86_64',
    Abi.macosArm64 => 'macos-arm64',
    _ => null,
  };
}
