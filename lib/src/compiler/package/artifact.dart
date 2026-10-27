import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pub_semver/pub_semver.dart';

/// A native build manifest to include in an npm package.
final class NativeArtifact {
  const NativeArtifact(this.manifest);

  /// The `.napi.json` file produced by a package build.
  final File manifest;
}

enum NativePlatform {
  macosArm64('macos_arm64', 'darwin', 'arm64', 'darwin-arm64'),
  linuxArm64('linux_arm64', 'linux', 'arm64', 'linux-arm64-gnu', libc: 'glibc'),
  windowsX64('windows_x64', 'win32', 'x64', 'win32-x64');

  const NativePlatform(this.id, this.os, this.cpu, this.npmSuffix, {this.libc});

  final String id;
  final String os;
  final String cpu;
  final String npmSuffix;
  final String? libc;
  String get runtimeKey => '$os-$cpu';
}

final class Artifact {
  Artifact._({
    required this.platform,
    required this.napi,
    required this.nodeConstraint,
    required this.exports,
    required this.binary,
    required this.declarations,
    required this.notices,
    required this.hashes,
  });

  final NativePlatform platform;
  final int napi;
  final VersionConstraint nodeConstraint;
  String get node => canonicalConstraint(nodeConstraint);
  final List<({String name, String kind})> exports;
  final File binary;
  final File declarations;
  final File notices;
  final ({String binary, String declarations, String notices}) hashes;

  static Future<Artifact> create(
    Map<String, Object?> report, {
    required File binary,
    required File declarations,
    required File notices,
  }) async {
    if (report['format'] != 1) {
      throw const FormatException('Unsupported native artifact format.');
    }
    final platform = NativePlatform.values
        .where((value) => value.id == report['platform'])
        .firstOrNull;
    if (platform == null) {
      throw FormatException(
        'Unsupported native platform: ${report['platform']}.',
      );
    }
    final napi = report['napi'];
    if (napi is! int || napi < 1) {
      throw const FormatException(
        'Native artifact requires a Node-API version.',
      );
    }
    final node = report['node'];
    if (node is! String || node.trim().isEmpty) {
      throw const FormatException('Native artifact requires a Node.js range.');
    }
    final nodeConstraint = VersionConstraint.unionOf(
      node.split('||').map((part) {
        if (part.trim().isEmpty) {
          throw const FormatException('Empty Node.js version range.');
        }
        return part.trim() == '*'
            ? VersionConstraint.any
            : VersionConstraint.parse(part.trim());
      }),
    );
    if (nodeConstraint.isEmpty) {
      throw const FormatException(
        'Native artifact has an empty Node.js range.',
      );
    }
    final entries = report['exports'];
    if (entries is! List || entries.isEmpty) {
      throw const FormatException(
        'Native artifacts require annotated exports.',
      );
    }
    final exports = <({String name, String kind})>[];
    final names = <String>{};
    for (final entry in entries) {
      final value = _object(entry, 'export');
      final name = value['name'];
      final kind = value['kind'];
      if (name is! String ||
          !RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$').hasMatch(name) ||
          _reservedNames.contains(name) ||
          ((kind == 'class' || kind == 'enum') &&
              _reservedTypeNames.contains(name))) {
        throw FormatException('Invalid native export name: $name.');
      }
      if (kind != 'class' &&
          kind != 'function' &&
          kind != 'enum' &&
          kind != 'value') {
        throw FormatException('Unsupported native export kind: $kind.');
      }
      if (!names.add(name)) {
        throw FormatException('Duplicate native export: $name.');
      }
      exports.add((name: name, kind: kind as String));
    }
    final checkedBinary = await _regularFile(binary);
    final checkedDeclarations = await _regularFile(declarations);
    final checkedNotices = await _regularFile(notices);
    await _checkBinary(checkedBinary, platform);
    return Artifact._(
      platform: platform,
      napi: napi,
      nodeConstraint: nodeConstraint,
      exports: List.unmodifiable(exports),
      binary: checkedBinary,
      declarations: checkedDeclarations,
      notices: checkedNotices,
      hashes: (
        binary: await _hash(checkedBinary),
        declarations: await _hash(checkedDeclarations),
        notices: await _hash(checkedNotices),
      ),
    );
  }

  static Future<Artifact> read(NativeArtifact input) async {
    final manifest = await _regularFile(input.manifest);
    final report = _object(
      jsonDecode(await manifest.readAsString()),
      'manifest',
    );
    if (report['kind'] != 'native') {
      throw const FormatException('Expected a native artifact manifest.');
    }
    final base = manifest.parent;
    final files = _files(report['files']);
    for (final path in files) {
      await _resolveFile(base, path);
    }
    Future<({File file, String hash})> reference(String field) async {
      final entry = _object(report[field], field);
      final path = _relative(entry['path']);
      if (!files.contains(path)) {
        throw FormatException(
          'Artifact $field is missing from its files list.',
        );
      }
      final expected = entry['sha256'];
      if (expected is! String ||
          !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(expected)) {
        throw FormatException('Invalid SHA-256 for artifact $field.');
      }
      final file = await _resolveFile(base, path);
      return (file: file, hash: expected.toLowerCase());
    }

    final binary = await reference('binary');
    final declarations = await reference('declarations');
    final notices = await reference('notices');
    final artifact = await create(
      report,
      binary: binary.file,
      declarations: declarations.file,
      notices: notices.file,
    );
    if (artifact.hashes !=
        (
          binary: binary.hash,
          declarations: declarations.hash,
          notices: notices.hash,
        )) {
      throw const FormatException('Native artifact content has changed.');
    }
    return artifact;
  }

  Future<Artifact> copyTo(Directory directory) async {
    await directory.create(recursive: true);
    final root = Directory(await directory.resolveSymbolicLinks());
    Future<File> copy(File source, String name, String expected) async {
      final target = File.fromUri(root.uri.resolve(name));
      final type = await FileSystemEntity.type(target.path, followLinks: false);
      if (type != FileSystemEntityType.notFound &&
          type != FileSystemEntityType.file) {
        throw FormatException('Cannot replace artifact file: ${target.path}.');
      }
      await source.copy(target.path);
      if (await _hash(target) != expected) {
        throw FormatException(
          'Native artifact content has changed: ${source.path}.',
        );
      }
      return target;
    }

    return Artifact._(
      platform: platform,
      napi: napi,
      nodeConstraint: nodeConstraint,
      exports: exports,
      binary: await copy(binary, 'addon.node', hashes.binary),
      declarations: await copy(
        declarations,
        'index.d.cts',
        hashes.declarations,
      ),
      notices: await copy(notices, 'NOTICES', hashes.notices),
      hashes: hashes,
    );
  }

  Future<Map<String, Object?>> manifest(
    Directory base, {
    required List<String> files,
  }) async {
    final root = Directory(await base.resolveSymbolicLinks());
    final owned = _files(files);
    Future<Map<String, String>> reference(File file, String expected) async {
      final rootSegments = root.uri.pathSegments;
      final segments = file.absolute.uri.pathSegments;
      final prefix = rootSegments.where((part) => part.isNotEmpty).toList();
      final path = segments.where((part) => part.isNotEmpty).toList();
      if (path.length <= prefix.length ||
          !Iterable<int>.generate(
            prefix.length,
          ).every((i) => path[i] == prefix[i])) {
        throw FormatException(
          'Artifact file is outside its directory: ${file.path}.',
        );
      }
      final relative = _relative(path.skip(prefix.length).join('/'));
      if (!owned.contains(relative)) {
        throw FormatException(
          'Artifact file is missing from files: $relative.',
        );
      }
      final checked = await _resolveFile(root, relative);
      if (await _hash(checked) != expected) {
        throw FormatException(
          'Native artifact content has changed: $relative.',
        );
      }
      return {'path': relative, 'sha256': expected};
    }

    return {
      'format': 1,
      'kind': 'native',
      'platform': platform.id,
      'napi': napi,
      'node': node,
      'exports': [
        for (final entry in exports) {'name': entry.name, 'kind': entry.kind},
      ],
      'binary': await reference(binary, hashes.binary),
      'declarations': await reference(declarations, hashes.declarations),
      'notices': await reference(notices, hashes.notices),
      'files': owned,
    };
  }
}

String canonicalConstraint(VersionConstraint constraint) => constraint.isAny
    ? '*'
    : constraint is VersionUnion
    ? constraint.ranges.join(' || ')
    : '$constraint';

Map<String, Object?> _object(Object? value, String label) {
  if (value is! Map<String, Object?>) {
    throw FormatException('Invalid native artifact $label.');
  }
  return value;
}

List<String> _files(Object? value) {
  if (value is! List || value.isEmpty) {
    throw const FormatException('Native artifact requires a files list.');
  }
  final files = value.map(_relative).toList();
  if (files.toSet().length != files.length) {
    throw const FormatException('Duplicate path in native artifact files.');
  }
  return files;
}

String _relative(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.contains(RegExp(r'[:\\\x00]')) ||
      value
          .split('/')
          .any((part) => part.isEmpty || part == '.' || part == '..')) {
    throw FormatException('Invalid relative artifact path: $value.');
  }
  return value;
}

Future<File> _regularFile(File file) async {
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw FormatException('Artifact must be a regular file: ${file.path}.');
  }
  return File(await file.resolveSymbolicLinks());
}

Future<File> _resolveFile(Directory base, String path) async {
  final segments = _relative(path).split('/');
  var uri = base.uri;
  for (var i = 0; i < segments.length; ++i) {
    uri = uri.resolveUri(Uri(path: segments[i]));
    final type = await FileSystemEntity.type(
      File.fromUri(uri).path,
      followLinks: false,
    );
    final last = i == segments.length - 1;
    if (type !=
        (last ? FileSystemEntityType.file : FileSystemEntityType.directory)) {
      throw FormatException(
        'Artifact path must not contain links or missing files: $path.',
      );
    }
    if (!last) uri = Uri.parse('$uri/');
  }
  return File.fromUri(uri);
}

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<void> _checkBinary(File file, NativePlatform platform) async {
  final handle = await file.open();
  try {
    final length = await handle.length();
    final header = await handle.read(64);
    var matches = false;
    if (header.length == 64) {
      final data = ByteData.sublistView(header);
      matches = switch (platform) {
        NativePlatform.macosArm64 =>
          data.getUint32(0, Endian.little) == 0xfeedfacf &&
              data.getUint32(4, Endian.little) == 0x0100000c &&
              data.getUint32(12, Endian.little) == 6,
        NativePlatform.linuxArm64 =>
          data.getUint32(0, Endian.big) == 0x7f454c46 &&
              header[4] == 2 &&
              header[5] == 1 &&
              header[6] == 1 &&
              data.getUint16(16, Endian.little) == 3 &&
              data.getUint16(18, Endian.little) == 183,
        NativePlatform.windowsX64 => false,
      };
      if (platform == NativePlatform.windowsX64 &&
          header[0] == 0x4d &&
          header[1] == 0x5a) {
        final offset = data.getUint32(0x3c, Endian.little);
        if (offset >= 64 && offset <= length - 26) {
          await handle.setPosition(offset);
          final pe = ByteData.sublistView(await handle.read(26));
          matches =
              pe.getUint32(0, Endian.little) == 0x00004550 &&
              pe.getUint16(4, Endian.little) == 0x8664 &&
              pe.getUint16(20, Endian.little) >= 2 &&
              pe.getUint16(22, Endian.little) & 0x2000 != 0 &&
              pe.getUint16(24, Endian.little) == 0x20b;
        }
      }
    }
    if (!matches) {
      throw FormatException(
        'Native binary does not match ${platform.id}: ${file.path}.',
      );
    }
  } finally {
    await handle.close();
  }
}

const _reservedNames = {
  'arguments',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'debugger',
  'default',
  'delete',
  'do',
  'else',
  'enum',
  'eval',
  'export',
  'extends',
  'false',
  'finally',
  'for',
  'function',
  'if',
  'implements',
  'import',
  'in',
  'instanceof',
  'interface',
  'let',
  'new',
  'null',
  'package',
  'private',
  'protected',
  'public',
  'return',
  'static',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'typeof',
  'var',
  'void',
  'while',
  'with',
  'yield',
};

const _reservedTypeNames = {
  'any',
  'unknown',
  'never',
  'number',
  'bigint',
  'boolean',
  'string',
  'symbol',
  'void',
  'object',
  'undefined',
};
