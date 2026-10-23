import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:napi/build.dart';
import 'package:napi/src/build/output_ownership.dart';
import 'package:napi/src/build/publish.dart';
import 'package:napi/src/compiler/native/platform.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_aot_adapter.dart';
import 'package:test/test.dart';

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

  test('native-only assembly includes both platforms without Wasm or install scripts', () async {
    await assemblePackage(
      modules: modules.take(2).toList(),
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
    });
    expect(await OutputOwnership.read(output), isNotNull);
  });

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
    await assemblePackage(modules: modules, output: output, metadata: metadata);
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
    await assembleWasmPackage(
      module: modules.last,
      output: output,
      metadata: metadata,
    );
    expect(File('${output.path}/native/module.mjs').existsSync(), isFalse);
    expect(await OutputOwnership.read(output), isNotNull);
  });
}
