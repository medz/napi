import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'build.dart';
import 'metadata.dart';
import 'output.dart';
import 'package.dart';
import 'publish.dart';

/// Prepare and publish a versioned set of npm packages from existing modules.
///
/// Run [prepare] before inspecting the packages and tarballs. [publish] uploads
/// those exact tarballs, skips identical published versions, and stops on a
/// conflict. Native payloads are published before the entry package. npm handles
/// registry authentication and trusted publishing.
final class PackageRelease {
  PackageRelease({
    required List<BuiltModule> modules,
    required this.output,
    required this.name,
    required this.version,
    this.target = BuildTarget.native,
    Map<String, Object?> metadata = const {},
    Map<String, File> assets = const {},
  }) : modules = List.unmodifiable(modules),
       metadata = Map.unmodifiable(metadata),
       assets = Map.unmodifiable(assets);

  final List<BuiltModule> modules;
  final Directory output;
  final String name;
  final String version;
  final BuildTarget target;
  final Map<String, Object?> metadata;
  final Map<String, File> assets;

  /// Create inspectable package directories and fixed tarballs in a new output.
  /// No registry writes occur. Existing preparations are never replaced.
  Future<Directory> prepare() async {
    for (final field in ['name', 'version']) {
      if (metadata.containsKey(field)) {
        throw ArgumentError('Supply "$field" through PackageRelease.$field.');
      }
    }
    final supplied = packageMetadata({
      ...metadata,
      'name': name,
      'version': version,
    });
    final destination = output.absolute;
    await checkOutputInputs(destination, [
      for (final module in modules) module.directory,
      ...assets.values,
    ]);
    if (await FileSystemEntity.type(destination.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw ArgumentError('Release output already exists: ${destination.path}');
    }
    await destination.parent.create(recursive: true);
    final staging = await destination.parent.createTemp('.napi-release-');
    var committed = false;
    try {
      final packages =
          modules.any((module) => module.target == BuildTarget.native)
          ? await assemblePackageSet(
              modules: modules,
              output: Directory('${staging.path}/packages'),
              metadata: supplied,
              target: target,
              assets: assets,
            )
          : [
              await assemblePackage(
                modules: modules,
                output: Directory('${staging.path}/packages/package'),
                metadata: supplied,
                target: target,
                assets: assets,
              ),
            ];
      final tarballs = await Directory('${staging.path}/tarballs').create();
      final prepared = <Map<String, Object?>>[];
      for (final directory in packages) {
        final result = await _npm([
          'pack',
          '--ignore-scripts',
          '--json',
          '--offline',
          '--pack-destination',
          tarballs.path,
        ], cwd: directory.path);
        final rows = jsonDecode(result.stdout as String);
        if (rows is! List || rows.length != 1 || rows.single is! Map) {
          throw const FormatException('npm pack did not return one package.');
        }
        final packed = rows.single as Map;
        final filename = packed['filename'];
        if (filename is! String ||
            path.basename(filename) != filename ||
            !filename.endsWith('.tgz')) {
          throw const FormatException(
            'npm pack returned an invalid tarball path.',
          );
        }
        final package = jsonDecode(
          await File('${directory.path}/package.json').readAsString(),
        ) as Map;
        final tarball = File('${tarballs.path}/$filename');
        final integrity = await _integrity(tarball);
        if (packed['name'] != package['name'] ||
            packed['version'] != version ||
            packed['integrity'] != integrity) {
          throw StateError(
            'npm pack output does not match ${package['name']}@$version.',
          );
        }
        prepared.add({
          'name': package['name'],
          'version': version,
          'directory': path.relative(directory.path, from: staging.path),
          'tarball': 'tarballs/$filename',
          'integrity': integrity,
        });
      }
      await File('${staging.path}/.napi-release.json').writeAsString(
        '${const JsonEncoder.withIndent('  ').convert({'format': 1, 'name': name, 'version': version, 'publishConfig': supplied['publishConfig'], 'packages': prepared})}\n',
      );
      publishDirectory(staging, destination);
      committed = true;
      return destination;
    } finally {
      if (!committed) await cleanBuildStaging(staging, committed: false);
    }
  }

  /// Publish a previous preparation. A retry never repacks or overwrites a
  /// registry version. Already published packages keep their existing tags.
  Future<void> publish({Uri? registry, String? tag, NpmAccess? access}) async {
    final destination = output.absolute;
    await checkOutputPath(destination.path);
    final record = await _readJson(
      File('${destination.path}/.napi-release.json'),
    );
    if (record['format'] != 1 ||
        record['name'] != name ||
        record['version'] != version) {
      throw const FormatException(
        'Prepared release name or version does not match this declaration.',
      );
    }
    packageMetadata({'name': name, 'version': version});
    final rows = record['packages'];
    if (rows is! List || rows.isEmpty) {
      throw const FormatException('Prepared release has no packages.');
    }
    final packages = <_PreparedPackage>[];
    final names = <String>{};
    for (final row in rows) {
      if (row is! Map ||
          row['version'] != version ||
          row['name'] is! String ||
          row['tarball'] is! String ||
          row['integrity'] is! String) {
        throw const FormatException('Invalid prepared package.');
      }
      final packageName = row['name'] as String;
      packageMetadata({'name': packageName, 'version': version});
      final relative = row['tarball'] as String;
      if (!names.add(packageName) ||
          (packageName != name && !packageName.startsWith('$name-')) ||
          path.posix.dirname(relative) != 'tarballs' ||
          path.posix.basename(relative).contains('\\') ||
          !relative.endsWith('.tgz')) {
        throw const FormatException(
          'Invalid prepared package name or tarball path.',
        );
      }
      final file = File('${destination.path}/$relative');
      if (await _integrity(file) != row['integrity']) {
        throw StateError('Prepared tarball changed: $relative');
      }
      packages.add(
        _PreparedPackage(packageName, file, row['integrity'] as String),
      );
    }
    if (packages.last.name != name) {
      throw const FormatException('The entry package must be last.');
    }
    final config = record['publishConfig'];
    if (config != null && config is! Map) {
      throw const FormatException('publishConfig must be a map.');
    }
    final scope = name.startsWith('@') ? name.split('/').first : null;
    final configured =
        registry?.toString() ??
        (scope == null ? null : (config as Map?)?['$scope:registry']) ??
        (config as Map?)?['registry'] ??
        (scope == null ? null : await _npmConfig('$scope:registry')) ??
        await _npmConfig('registry');
    final selected = configured is String ? Uri.tryParse(configured) : null;
    if (selected == null ||
        !{'https', 'http'}.contains(selected.scheme) ||
        selected.host.isEmpty ||
        selected.userInfo.isNotEmpty ||
        selected.hasQuery ||
        selected.hasFragment) {
      throw ArgumentError('npm registry must be an absolute HTTP(S) URL.');
    }
    final registryOptions = [
      '--registry=${selected.toString()}',
      if (scope != null) '--$scope:registry=${selected.toString()}',
    ];
    final done = <String>{};
    try {
      // Discover all conflicts before writing any new registry versions.
      for (final package in packages) {
        if (await _published(package, registryOptions)) done.add(package.name);
      }
      for (final package in packages) {
        if (done.contains(package.name)) {
          stdout.writeln('Already published ${package.name}@$version');
          continue;
        }
        // Verify again immediately before npm opens the prepared tarball.
        if (await _integrity(package.tarball) != package.integrity) {
          throw StateError('Prepared tarball changed: ${package.tarball.path}');
        }
        final process = await Process.start(
          _npmExecutable,
          [
            'publish',
            package.tarball.path,
            '--ignore-scripts',
            ...registryOptions,
            if (tag != null) '--tag=$tag',
            if (access != null) '--access=${access.name}',
          ],
          mode: ProcessStartMode.inheritStdio,
          runInShell: Platform.isWindows,
        );
        final code = await process.exitCode;
        // A network failure can occur after the registry accepted the upload.
        // Read back the digest before deciding whether this package is pending.
        if (!await _published(package, registryOptions)) {
          throw StateError(
            'npm publish did not confirm ${package.name}@$version (exit $code).',
          );
        }
        done.add(package.name);
        stdout.writeln('Published ${package.name}@$version');
      }
    } catch (error) {
      throw StateError(
        '$error\nConfirmed: ${done.isEmpty ? 'none' : done.join(', ')}.\n'
        'Pending: ${packages.where((p) => !done.contains(p.name)).map((p) => p.name).join(', ')}. '
        'Retry publish with the same prepared release.',
      );
    }
  }

  Future<bool> _published(
    _PreparedPackage package,
    List<String> registry,
  ) async {
    final result = await _npm([
      'view',
      '${package.name}@$version',
      'dist.integrity',
      '--json',
      '--prefer-online',
      '--fetch-retries=0',
      ...registry,
    ], check: false);
    Object? value;
    try {
      value = jsonDecode(result.stdout as String);
    } on FormatException {
      /* npm diagnostic below. */
    }
    if (result.exitCode != 0) {
      if (value is Map &&
          value['error'] is Map &&
          (value['error'] as Map)['code'] == 'E404') {
        return false;
      }
      throw ProcessException(
        _npmExecutable,
        ['view', '${package.name}@$version'],
        '${result.stdout}${result.stderr}',
        result.exitCode,
      );
    }
    if (value != package.integrity) {
      throw StateError(
        'Registry integrity differs for ${package.name}@$version; it will not be overwritten.',
      );
    }
    return true;
  }

  /// Use this declaration as a custom Dart script: prepare, inspect, publish.
  Future<void> run(List<String> arguments) async {
    final parser = ArgParser()
      ..addFlag('help', abbr: 'h', negatable: false)
      ..addOption('registry', help: 'Registry for publish.')
      ..addOption('tag', help: 'npm distribution tag for new versions.')
      ..addOption('access', allowed: ['public', 'restricted']);
    try {
      final options = parser.parse(arguments);
      if (options.flag('help')) {
        stdout.writeln(
          'Usage: dart run ${path.relative(Platform.script.toFilePath())} [prepare|publish] [options]\n\n${parser.usage}',
        );
        return;
      }
      if (options.rest.length > 1) {
        throw const FormatException('Choose either prepare or publish.');
      }
      final command = options.rest.isEmpty ? 'prepare' : options.rest.single;
      if (command == 'prepare') {
        if (['registry', 'tag', 'access'].any(options.wasParsed)) {
          throw const FormatException(
            'Registry, tag and access options require publish.',
          );
        }
        stdout.writeln('Prepared ${(await prepare()).path}');
      } else if (command == 'publish') {
        await publish(
          registry: options.option('registry') == null
              ? null
              : Uri.parse(options.option('registry')!),
          tag: options.option('tag'),
          access: options.option('access') == null
              ? null
              : NpmAccess.values.byName(options.option('access')!),
        );
      } else {
        throw FormatException('Unknown command: $command');
      }
    } on FormatException catch (error) {
      stderr.writeln('napi: ${error.message}');
      exitCode = 64;
    } on ArgumentError catch (error) {
      stderr.writeln('napi: ${error.message}');
      exitCode = 64;
    } on StateError catch (error) {
      stderr.writeln('napi: ${error.message}');
      exitCode = 1;
    } on IOException catch (error) {
      stderr.writeln('napi: $error');
      exitCode = 1;
    }
  }
}

/// npm access for newly published versions. Existing versions are unchanged.
enum NpmAccess { public, restricted }

final class _PreparedPackage {
  const _PreparedPackage(this.name, this.tarball, this.integrity);
  final String name;
  final File tarball;
  final String integrity;
}

String get _npmExecutable => Platform.isWindows ? 'npm.cmd' : 'npm';

Future<ProcessResult> _npm(
  List<String> arguments, {
  String? cwd,
  bool check = true,
}) async {
  final result = await Process.run(
    _npmExecutable,
    arguments,
    workingDirectory: cwd,
    runInShell: Platform.isWindows,
  );
  if (check && result.exitCode != 0) {
    throw ProcessException(
      _npmExecutable,
      arguments,
      '${result.stdout}${result.stderr}',
      result.exitCode,
    );
  }
  return result;
}

Future<String?> _npmConfig(String key) async {
  final value = (await _npm(['config', 'get', key])).stdout.toString().trim();
  return value.isEmpty || value == 'undefined' || value == 'null'
      ? null
      : value;
}

Future<String> _integrity(File file) async {
  await checkOutputPath(file.path);
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw ArgumentError('Prepared tarball is not a regular file: ${file.path}');
  }
  return 'sha512-${base64Encode((await sha512.bind(file.openRead()).first).bytes)}';
}

Future<Map<String, dynamic>> _readJson(File file) async {
  await checkOutputPath(file.path);
  if (await FileSystemEntity.type(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw ArgumentError('Release metadata is not a regular file: ${file.path}');
  }
  final value = jsonDecode(await file.readAsString());
  if (value is! Map<String, dynamic>) {
    throw const FormatException('Invalid release metadata.');
  }
  return value;
}
