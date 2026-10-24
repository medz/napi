import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:napi/build.dart';
import 'package:napi/src/build/output_ownership.dart';
import 'package:napi/src/build/publish.dart';
import 'package:napi/src/compiler/native/platform.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_aot_adapter.dart';
import 'package:test/test.dart';

import '../support/process.dart';
import '../support/commands.dart' show nodeExecutables;

void main() {
  late Directory root;
  late Directory output;
  late List<BuiltModule> modules;
  const metadata = {'name': '@test/platforms', 'version': '1.0.0'};
  final contract = {
    'format': 1,
    'exports': ['Counter'],
    'sha256': sha256.convert(utf8.encode('Counter contract')).toString(),
  };

  Future<BuiltModule> fixture(NativePlatform? platform) async {
    final directory = await Directory(
      '${root.path}/${platform?.packageId ?? 'wasm'}',
    ).create();
    final runtime = platform == null
        ? null
        : 'libnapi_runtime_fixture.${platform.runtimeExtension}';
    final names = packageArtifactNames(
      {platform == null ? 'wasm' : 'native'},
      runtime,
      calls: false,
    );
    for (final name in names) {
      await File('${directory.path}/$name').writeAsString(
        name.startsWith('module.d.')
            ? 'export declare class Counter {}\n'
            : name == 'module.mjs'
            ? 'export class Counter { value = 0; increment() { return ++this.value; } }\n'
            : name,
      );
    }
    if (platform != null) {
      final hashes = <String, String>{};
      for (final name in [
        'bridge.node',
        runtime!,
        'DART_LICENSE',
        'DART_AUTHORS',
        'NAPI_LICENSE',
      ]) {
        hashes[name] = sha256
            .convert(await File('${directory.path}/$name').readAsBytes())
            .toString();
      }
      await File('${directory.path}/runtime.json').writeAsString(
        jsonEncode({
          'format': 1,
          'sdkVersion': '3.13.5',
          'sdkRevision': nativeSdkRevision,
          'platform': platform.platform,
          'architecture': platform.architecture,
          if (platform.minimumOsVersion != null)
            'minimumOsVersion': platform.minimumOsVersion,
          if (platform.libc != null) 'libc': platform.libc,
          if (platform.minimumLibcVersion != null)
            'minimumLibcVersion': platform.minimumLibcVersion,
          'abi': 15,
          'identity': 'fixture',
          'bridge': 'bridge.node',
          'runtime': runtime,
          'files': hashes,
        }),
      );
    }
    await writeOutputOwnership(
      directory,
      kind: OutputKind.module,
      targets: {platform == null ? 'wasm' : 'native'},
      root: platform == null ? 'wasm' : 'native',
      runtime: runtime,
      calls: false,
      moduleContract: contract,
    );
    return BuiltModule(
      directory,
      '3.13.5',
      target: platform == null ? BuildTarget.wasm : BuildTarget.native,
    );
  }

  Future<void> changeContract(BuiltModule module, Object? value) async {
    final marker = File('${module.directory.path}/$outputOwnershipFile');
    final record = jsonDecode(await marker.readAsString()) as Map;
    record['moduleContract'] = value;
    await marker.writeAsString(jsonEncode(record));
  }

  setUp(() async {
    root = await Directory(await Directory.systemTemp.resolveSymbolicLinks())
        .createTemp('platform packages ');
    output = Directory('${root.path}/package');
    modules = [
      for (final platform in NativePlatform.values) await fixture(platform),
      await fixture(null),
    ];
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'platform package set keeps native payloads out of the entry package',
    () async {
      final packages = await assemblePackageSet(
        modules: modules,
        output: output,
        metadata: {
          ...metadata,
          'optionalDependencies': {'unrelated': '2.0.0'},
          'scripts': {'test': 'echo author script'},
        },
      );
      expect(packages.last.path, '${output.path}/package');
      final entry = jsonDecode(
        await File('${packages.last.path}/package.json').readAsString(),
      ) as Map;
      expect(entry['optionalDependencies'], {
        'unrelated': '2.0.0',
        for (final platform in NativePlatform.values)
          '@test/platforms-${platform.packageId}': '1.0.0',
      });
      expect(
        (entry['files'] as List).where(
          (p) => p.toString().startsWith('native/'),
        ),
        ['native/module.mjs', 'native/module.d.mts'],
      );
      expect(
        File('${packages.last.path}/wasm/module.wasm').existsSync(),
        isTrue,
      );
      for (final platform in NativePlatform.values) {
        final directory = Directory('${output.path}/${platform.packageId}');
        final package = jsonDecode(
          await File('${directory.path}/package.json').readAsString(),
        ) as Map;
        expect(package['name'], '@test/platforms-${platform.packageId}');
        expect(package['version'], '1.0.0');
        expect(package['os'], [platform.nodePlatform]);
        expect(package['cpu'], [platform.architecture]);
        expect(package['libc'], platform.libc == null ? null : [platform.libc]);
        expect(package.containsKey('scripts'), isFalse);
        expect(package.containsKey('optionalDependencies'), isFalse);
        expect(File('${directory.path}/module.aot').existsSync(), isTrue);
        expect(await OutputOwnership.read(directory), isNotNull);
      }
      final owned = await OutputOwnership.read(packages.last);
      expect(owned!.metadata['optionalDependencies'], {'unrelated': '2.0.0'});
    },
  );

  test(
    'package sets reject mismatched contracts and leave no partial output',
    () async {
      await changeContract(modules.last, {...contract, 'sha256': '0' * 64});
      await expectLater(
        assemblePackageSet(
          modules: modules,
          output: output,
          metadata: metadata,
        ),
        throwsArgumentError,
      );
      expect(output.existsSync(), isFalse);
      expect(
        root.listSync().where(
          (entry) => entry.path.contains('.napi-package-set-'),
        ),
        isEmpty,
      );
    },
  );

  test('package sets do not overwrite previous output', () async {
    await output.create();
    final author = File('${output.path}/author.txt');
    await author.writeAsString('keep');
    await expectLater(
      assemblePackageSet(modules: modules, output: output, metadata: metadata),
      throwsArgumentError,
    );
    expect(await author.readAsString(), 'keep');
  });

  for (final field in [
    'dependencies',
    'optionalDependencies',
    'peerDependencies',
    'devDependencies',
  ]) {
    test('package sets reject a generated name in author $field', () async {
      await expectLater(
        assemblePackageSet(
          modules: modules,
          output: output,
          metadata: {
            ...metadata,
            field: {
              '@test/platforms-${NativePlatform.values.first.packageId}':
                  '1.0.0',
            },
          },
        ),
        throwsArgumentError,
      );
      expect(output.existsSync(), isFalse);
    });
  }

  test('entry package ownership rejects redirected platform dependencies', () async {
    final packages = await assemblePackageSet(
      modules: modules,
      output: output,
      metadata: metadata,
    );
    final manifest = File('${packages.last.path}/package.json');
    final package = jsonDecode(await manifest.readAsString()) as Map;
    (package['optionalDependencies']
            as Map)['@test/platforms-${NativePlatform.values.first.packageId}'] =
        '^1.0.0';
    await manifest.writeAsString(jsonEncode(package));
    await expectLater(OutputOwnership.read(packages.last), throwsArgumentError);
  });

  test(
    'npm installs only the selected optional platform and preserves loader errors',
    () async {
      await assemblePackageSet(
        modules: modules
            .where((module) => module.target == BuildTarget.native)
            .toList(),
        output: output,
        metadata: metadata,
      );
      for (final node in nodeExecutables()) {
        await runProcess(node, [
          'test/integration/optional_platforms.mjs',
          output.path,
        ], timeout: const Duration(minutes: 2));
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: Platform.isWindows,
  );

  test('native-only assembly includes all platforms without Wasm or install scripts', () async {
    await assemblePackage(
      modules: modules
          .where((module) => module.target == BuildTarget.native)
          .toList(),
      output: output,
      metadata: metadata,
    );
    final package = jsonDecode(
      await File('${output.path}/package.json').readAsString(),
    ) as Map;
    expect(package['exports'], {
      for (final name in ['.', './native'])
        name: {
          'types': './native/module.d.mts',
          'import': './native/module.mjs',
          'require': './native/module.mjs',
        },
    });
    for (final key in [
      'os',
      'cpu',
      'libc',
      'scripts',
      'optionalDependencies',
    ]) {
      expect(package.containsKey(key), isFalse);
    }
    expect(Directory('${output.path}/wasm').existsSync(), isFalse);
    for (final platform in NativePlatform.values) {
      expect(
        File('${output.path}/native/${platform.packageId}/module.aot')
            .existsSync(),
        isTrue,
      );
      expect(
        File('${output.path}/native/${platform.packageId}/$outputOwnershipFile')
            .existsSync(),
        isFalse,
      );
    }
    expect(await OutputOwnership.read(output), isNotNull);
  });

  test('dual assembly root can choose Wasm while native retains platform selection', () async {
    await assemblePackage(
      modules: modules,
      output: output,
      metadata: metadata,
      target: BuildTarget.wasm,
    );
    final package = jsonDecode(
      await File('${output.path}/package.json').readAsString(),
    ) as Map;
    final exports = package['exports'] as Map;
    expect(exports['.'], exports['./wasm']);
    expect(exports['.'], exports['./module.wasm']);
    expect(exports['./native'], {
      'types': './native/module.d.mts',
      'import': './native/module.mjs',
      'require': './native/module.mjs',
    });
    expect(await OutputOwnership.read(output), isNotNull);
  });

  for (final multiple in [false, true]) {
    test(
      'rebuild upgrades ESM-only native exports (platforms: $multiple)',
      () async {
        try {
          checkPackageRebuildFilesystem(root);
        } on UnsupportedError catch (error) {
          markTestSkipped(error.toString());
          return;
        }
        Future<Directory> assemble() => multiple
            ? assemblePackage(
                modules: modules,
                output: output,
                metadata: metadata,
              )
            : assembleNativePackage(
                module: modules.first,
                output: output,
                metadata: metadata,
              );
        await assemble();
        final manifest = File('${output.path}/package.json');
        final package = jsonDecode(await manifest.readAsString()) as Map;
        final exports = package['exports'] as Map;
        for (final entry in exports.values.cast<Map>()) {
          entry.remove('require');
        }
        await manifest.writeAsString(jsonEncode(package));
        expect(await OutputOwnership.read(output), isNotNull);
        exports['.']['require'] = './author.mjs';
        await manifest.writeAsString(jsonEncode(package));
        await expectLater(OutputOwnership.read(output), throwsArgumentError);
        exports['.'].remove('require');
        await manifest.writeAsString(jsonEncode(package));
        await File('${output.path}/author.txt').writeAsString('keep');
        await assemble();
        final updated = jsonDecode(await manifest.readAsString()) as Map;
        expect(
          updated['exports']['.']['require'],
          multiple ? './native/module.mjs' : './module.mjs',
        );
        expect(await File('${output.path}/author.txt').readAsString(), 'keep');
      },
    );
  }

  test('Wasm-only assembly stays independent of native platforms', () async {
    await assemblePackage(
      modules: [modules.last],
      output: output,
      metadata: metadata,
      target: BuildTarget.wasm,
    );
    expect(File('${output.path}/module.wasm').existsSync(), isTrue);
    expect(Directory('${output.path}/native').existsSync(), isFalse);
    expect(await OutputOwnership.read(output), isNotNull);
  });

  test('duplicate or absent targets fail before publishing', () async {
    for (final selected in [
      <BuiltModule>[],
      [modules.first, modules.first],
      [modules.last],
    ]) {
      await expectLater(
        assemblePackage(modules: selected, output: output, metadata: metadata),
        throwsArgumentError,
      );
      expect(output.existsSync(), isFalse);
    }
    await expectLater(
      assemblePackage(
        modules: [modules.last, modules.last],
        target: BuildTarget.wasm,
        output: output,
        metadata: metadata,
      ),
      throwsArgumentError,
    );
  });

  test(
    'missing, changed and invalid contracts fail before publishing',
    () async {
      for (final change in [
        null,
        {...contract, 'format': 2},
        {
          ...contract,
          'exports': ['then'],
        },
        {
          ...contract,
          'sha256': sha256.convert([1]).toString(),
        },
      ]) {
        await changeContract(modules[1], change);
        await expectLater(
          assemblePackage(modules: modules, output: output, metadata: metadata),
          throwsArgumentError,
        );
        expect(output.existsSync(), isFalse);
      }
    },
  );

  test('edited module bytes are rejected before assembly', () async {
    await File('${modules.first.directory.path}/module.aot')
        .writeAsString('changed');
    await expectLater(
      assemblePackage(modules: modules, output: output, metadata: metadata),
      throwsArgumentError,
    );
    expect(output.existsSync(), isFalse);
  });

  test('rebuild moves between legacy and platform layouts and removes obsolete artifacts', () async {
    try {
      checkPackageRebuildFilesystem(root);
    } on UnsupportedError catch (error) {
      markTestSkipped(error.toString());
      return;
    }
    await assembleNativePackage(
      module: modules.first,
      output: output,
      metadata: metadata,
    );
    await File('${output.path}/author.txt').writeAsString('keep');
    final nested = await Directory('${output.path}/author/nested')
        .create(recursive: true);
    await File('${nested.path}/notes.txt').writeAsString('nested author');
    await assemblePackage(modules: modules, output: output, metadata: metadata);
    final ownership = (await OutputOwnership.read(output))!;
    expect(
      ownership.recoveryEntries,
      contains('native/macos-arm64/module.aot'),
    );
    expect(ownership.recoveryEntries, contains('author/nested/notes.txt'));
    expect(File('${output.path}/module.aot').existsSync(), isFalse);
    final package = jsonDecode(
      await File('${output.path}/package.json').readAsString(),
    ) as Map;
    expect(package.containsKey('os'), isFalse);
    await assemblePackage(
      modules: [modules[1]],
      output: output,
      metadata: metadata,
    );
    expect(
      File('${output.path}/native/macos-arm64/module.aot').existsSync(),
      isFalse,
    );
    expect(File('${output.path}/wasm/module.wasm').existsSync(), isFalse);
    expect(await File('${output.path}/author.txt').readAsString(), 'keep');
    expect(
      await File('${nested.path}/notes.txt').readAsString(),
      'nested author',
    );
    await assembleWasmPackage(
      module: modules.last,
      output: output,
      metadata: metadata,
    );
    expect(File('${output.path}/native/module.mjs').existsSync(), isFalse);
    expect(await OutputOwnership.read(output), isNotNull);
  });
}
