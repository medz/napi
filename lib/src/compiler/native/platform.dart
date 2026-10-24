/// Fixed runtime profiles shared by bundle validation and generated packages.
enum NativePlatform {
  macosArm64('macos', 'arm64', 'darwin', 'dylib', minimumOsVersion: '14.0'),
  macosX64('macos', 'x64', 'darwin', 'dylib', minimumOsVersion: '14.0'),
  linuxX64(
    'linux',
    'x64',
    'linux',
    'so',
    libc: 'glibc',
    minimumLibcVersion: '2.28',
  ),
  linuxArm64(
    'linux',
    'arm64',
    'linux',
    'so',
    libc: 'glibc',
    minimumLibcVersion: '2.28',
  );

  final String platform;
  final String architecture;
  final String nodePlatform;
  final String runtimeExtension;
  final String? minimumOsVersion;
  final String? libc;
  final String? minimumLibcVersion;

  const NativePlatform(
    this.platform,
    this.architecture,
    this.nodePlatform,
    this.runtimeExtension, {
    this.minimumOsVersion,
    this.libc,
    this.minimumLibcVersion,
  });

  String get description => switch (this) {
    macosArm64 => 'macOS arm64',
    macosX64 => 'macOS x64',
    linuxX64 => 'Linux x64 with glibc $minimumLibcVersion or newer',
    linuxArm64 => 'Linux arm64 with glibc $minimumLibcVersion or newer',
  };

  String get packageId =>
      '$platform-$architecture${libc == null ? '' : '-$libc'}';

  static NativePlatform? fromManifest(Map<String, dynamic> manifest) => values
      .where(
        (profile) =>
            manifest['platform'] == profile.platform &&
            manifest['architecture'] == profile.architecture &&
            manifest['minimumOsVersion'] == profile.minimumOsVersion &&
            manifest['libc'] == profile.libc &&
            manifest['minimumLibcVersion'] == profile.minimumLibcVersion,
      )
      .singleOrNull;
}

bool nativeVersionAtLeast(String version, String minimum) {
  List<int>? parse(String value) {
    if (!RegExp(r'^[0-9]+(?:\.[0-9]+)*$').hasMatch(value)) return null;
    final parts = value.split('.').map(int.tryParse).toList();
    return parts.any((part) => part == null) ? null : parts.cast<int>();
  }

  final actual = parse(version), required = parse(minimum);
  if (actual == null || required == null) return false;
  final length = actual.length > required.length
      ? actual.length
      : required.length;
  for (var index = 0; index < length; index++) {
    final left = index < actual.length ? actual[index] : 0;
    final right = index < required.length ? required[index] : 0;
    if (left != right) return left > right;
  }
  return true;
}
