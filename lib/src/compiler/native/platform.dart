import 'dart:ffi';
import 'dart:io';

String currentNativePlatform() {
  final platform = switch (Abi.current()) {
    Abi.linuxArm64 => 'linux_arm64',
    Abi.linuxX64 => 'linux_x64',
    Abi.macosArm64 => 'macos_arm64',
    Abi.macosX64 => 'macos_x64',
    Abi.windowsArm64 => 'windows_arm64',
    Abi.windowsX64 => 'windows_x64',
    final abi => throw UnsupportedError('Unsupported native platform: $abi'),
  };
  if (Platform.isLinux &&
      RegExp(
        r'/ld-musl-[^/\s]+\.so\.1(?:\s|$)',
      ).hasMatch(File('/proc/self/maps').readAsStringSync())) {
    return '${platform}_musl';
  }
  return platform;
}
