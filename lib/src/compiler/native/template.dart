import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../sdk.dart';

/// A prebuilt addon and the SDK used to build its embedded runtime.
final class NativeTemplate {
  NativeTemplate._(this.file, this.target, this.napi, this.revision, this.sdk);

  final File file;
  final String target;
  final int napi;
  final String revision;
  final String sdk;

  static Future<NativeTemplate> current(DartSdk compiler) async {
    final target = switch (Abi.current()) {
      Abi.linuxArm64 => 'linux_arm64',
      Abi.linuxX64 => 'linux_x64',
      Abi.windowsArm64 => 'windows_arm64',
      Abi.windowsX64 => 'windows_x64',
      Abi.macosArm64 => 'macos_arm64',
      Abi.macosX64 => 'macos_x64',
      final abi => throw UnsupportedError('Unsupported native platform: $abi'),
    };
    final uri = await Isolate.resolvePackageUri(
      Uri.parse('package:napi/src/compiler/templates/$target.node'),
    );
    if (uri == null || uri.scheme != 'file') {
      throw StateError('Cannot locate the napi package templates.');
    }
    final file = File.fromUri(uri);
    final metadata = File.fromUri(uri.resolve('$target.json'));
    if (!file.existsSync() || !metadata.existsSync()) {
      throw UnsupportedError('No precompiled addon template for $target.');
    }
    final value = jsonDecode(await metadata.readAsString());
    if (value is! Map<String, dynamic> ||
        value['target'] != target ||
        value['format'] != 1 ||
        value['sdk'] is! String ||
        value['revision'] is! String ||
        value['napi'] is! int ||
        value['sha256'] is! String) {
      throw FormatException(
        'Invalid addon template metadata: ${metadata.path}',
      );
    }
    if (compiler.revision != value['revision']) {
      throw StateError(
        'This addon template requires Dart SDK ${value['sdk']} '
        '(${value['revision']}); the current SDK is '
        '${compiler.version} (${compiler.revision}).',
      );
    }
    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString() != value['sha256']) {
      throw StateError('Addon template checksum mismatch: ${file.path}');
    }
    return NativeTemplate._(
      file,
      target,
      value['napi'] as int,
      value['revision'] as String,
      value['sdk'] as String,
    );
  }

  /// Packs an AOT ELF after the native image without rewriting machine code.
  Future<void> assemble(File snapshot, File output) async {
    final templateSize = await file.length();
    final snapshotSize = await snapshot.length();
    final input = await snapshot.open();
    try {
      final header = await input.read(20);
      final machine = target.endsWith('_arm64') ? 183 : 62;
      if (header.length < 20 ||
          header[0] != 0x7f ||
          header[1] != 0x45 ||
          header[2] != 0x4c ||
          header[3] != 0x46 ||
          header[4] != 2 ||
          header[5] != 1 ||
          ByteData.sublistView(header).getUint16(18, Endian.little) !=
              machine) {
        throw FormatException('Expected a $target AOT ELF snapshot.');
      }
    } finally {
      await input.close();
    }
    const alignment = 65536;
    final offset = (templateSize + alignment - 1) & -alignment;
    final footer = Uint8List(32)..setRange(0, 8, ascii.encode('NAPI AOT'));
    ByteData.sublistView(footer)
      ..setUint32(8, 1, Endian.little)
      ..setUint64(16, offset, Endian.little)
      ..setUint64(24, snapshotSize, Endian.little);
    final sink = output.openWrite();
    try {
      await sink.addStream(file.openRead());
      sink.add(Uint8List(offset - templateSize));
      await sink.addStream(snapshot.openRead());
      sink.add(footer);
      await sink.flush();
    } finally {
      await sink.close();
    }
  }
}
