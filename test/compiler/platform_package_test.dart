import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:napi/build.dart';
import 'package:napi/src/build/output_ownership.dart';
import 'package:napi/src/build/publish.dart';
import 'package:napi/src/compiler/native/platform.dart';
import 'package:test/test.dart';

import '../support/process.dart';
import '../support/package_module.dart';
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
      for (final platform in NativePlatform.values)
        await createPackageModule(root, platform, contract),
      await createPackageModule(root, null, contract),
    ];
  });
  tearDown(() => root.delete(recursive: true));

  test(
    'fallback requires both backends and a native root before creating output',
    () async {
      for (final selected in [
        [modules.first],
        [modules.last],
        modules,
      ]) {
        for (final set in [false, true]) {
          await expectLater(
            set
                ? assemblePackageSet(
                    modules: selected,
                    output: output,
                    metadata: metadata,
                    target: selected.length == modules.length
                        ? BuildTarget.wasm
                        : selected.first.target,
                    wasmFallback: true,
                  )
                : assemblePackage(
                    modules: selected,
                    output: output,
                    metadata: metadata,
                    target: selected.length == modules.length
                        ? BuildTarget.wasm
                        : selected.first.target,
                    wasmFallback: true,
                  ),
            throwsArgumentError,
          );
          expect(output.existsSync(), isFalse);
        }
      }
      await expectLater(
        buildPackage(
          library: Uri.file('${root.path}/absent.dart'),
          output: output,
          metadata: metadata,
          wasmFallback: true,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('wasmFallback'),
          ),
        ),
      );
      expect(output.existsSync(), isFalse);
    },
  );

  test(
    'ESM fallback selects only unsupported platforms and keeps require native',
    () async {
      await assemblePackage(
        modules: modules,
        output: output,
        metadata: metadata,
        wasmFallback: true,
      );
      expect(await OutputOwnership.read(output), isNotNull);
      final package = jsonDecode(
        await File('${output.path}/package.json').readAsString(),
      ) as Map;
      expect(package['exports']['.'], {
        'types': './native/module.d.mts',
        'import': './module.mjs',
        'require': './native/module.mjs',
      });
      await File('${output.path}/check.mjs').writeAsString(r"""
import assert from 'node:assert/strict';
import os from 'node:os';
import {createRequire, syncBuiltinESMExports} from 'node:module';
const mode = process.argv[2];
const require = createRequire(import.meta.url);
const host = mode === 'platform' ? ['freebsd', 'arm64']
  : mode === 'architecture' ? ['darwin', 's390x']
  : mode === 'macos' ? ['darwin', 'arm64']
  : mode.startsWith('windows-') ? ['win32', 'x64']
  : ['linux', 'x64'];
Object.defineProperty(process, 'platform', {value: host[0]});
Object.defineProperty(process, 'arch', {value: host[1]});
os.release = () => mode === 'windows-supported' ? '10.0.26100'
  : mode === 'windows-old' ? '6.3.9600'
  : mode === 'windows-unknown' ? 'unknown' : '22.0.0';
syncBuiltinESMExports();
Object.defineProperty(process, 'report', {value: {getReport: () => ({header: {
  glibcVersionRuntime: mode === 'supported' ? '2.28' : mode === 'glibc' ? '2.27' : undefined,
}})}});
if (mode === 'supported' || mode === 'windows-supported') {
  const common = require('@test/platforms');
  const root = await import('@test/platforms');
  const native = await import('@test/platforms/native');
  assert.equal(root.Counter, common.Counter);
  assert.equal(root.Counter, native.Counter);
  assert.equal(new root.Counter().value, 0);
} else {
  const root = await import('@test/platforms');
  const wasm = await import('@test/platforms/wasm');
  assert.equal(root.Counter, wasm.Counter);
  assert.equal(new root.Counter().value, 100);
  assert.throws(() => require('@test/platforms'), /native artifact/);
  await assert.rejects(import('@test/platforms/native'), /native artifact/);
}
""");
      for (final node in nodeExecutables()) {
        for (final mode in [
          'supported',
          'platform',
          'architecture',
          'macos',
          'windows-supported',
          'windows-old',
          'windows-unknown',
          'glibc',
          'musl',
        ]) {
          await runProcess(node, [
            '${output.path}/check.mjs',
            mode,
          ], timeout: const Duration(seconds: 20));
        }
      }
    },
  );

  test('supported native failures are not replaced by Wasm', () async {
    for (final set in [false, true]) {
      final Directory package;
      if (set) {
        package = (await assemblePackageSet(
          modules: modules,
          output: Directory('${root.path}/optional'),
          metadata: metadata,
          wasmFallback: true,
        )).last;
      } else {
        package = await assemblePackage(
          modules: modules,
          output: output,
          metadata: metadata,
          wasmFallback: true,
        );
      }
      await File('${package.path}/check.mjs').writeAsString(r"""
import assert from 'node:assert/strict';
import {writeFile, unlink} from 'node:fs/promises';
Object.defineProperty(process, 'platform', {value: 'linux'});
Object.defineProperty(process, 'arch', {value: 'x64'});
Object.defineProperty(process, 'report', {value: {getReport: () => ({header: {glibcVersionRuntime: '2.28'}})}});
const mode = process.argv[2];
const failure = globalThis.failure = new Error('native failure must survive');
const native = new URL('./native/linux-x64-glibc/module.mjs', import.meta.url);
if (mode === 'broken') await writeFile(native, 'throw globalThis.failure;');
if (mode === 'missing') await unlink(native);
let error;
try { await import('@test/platforms'); } catch (value) { error = value; }
assert(error instanceof Error);
if (mode === 'broken') assert.equal(error, failure);
else if (mode === 'missing') assert.equal(error.code, 'MODULE_NOT_FOUND');
else assert.match(error.message, /Missing optional native package/);
await assert.rejects(import('@test/platforms/native'), value => value === error);
""");
      for (final mode in set ? ['optional'] : ['broken', 'missing']) {
        await runProcess(nodeExecutables().first, [
          '${package.path}/check.mjs',
          mode,
        ], timeout: const Duration(seconds: 20));
      }
    }
  });

  test(
    'rebuild can enable and disable fallback without claiming author files',
    () async {
      try {
        checkPackageRebuildFilesystem(root);
      } on UnsupportedError catch (error) {
        markTestSkipped(error.toString());
        return;
      }
      await assemblePackage(
        modules: modules,
        output: output,
        metadata: metadata,
      );
      await File('${output.path}/author.txt').writeAsString('keep');
      for (final enabled in [true, false, true]) {
        await assemblePackage(
          modules: modules,
          output: output,
          metadata: metadata,
          wasmFallback: enabled,
        );
        expect(await OutputOwnership.read(output), isNotNull);
        expect(File('${output.path}/module.mjs').existsSync(), enabled);
        expect(await File('${output.path}/author.txt').readAsString(), 'keep');
      }
      await File('${output.path}/module.mjs').writeAsString('author edit');
      await expectLater(
        assemblePackage(modules: modules, output: output, metadata: metadata),
        throwsArgumentError,
      );
      expect(
        await File('${output.path}/module.mjs').readAsString(),
        'author edit',
      );
    },
  );

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

  test('package sets cannot occupy the reserved lock directory', () async {
    for (final name in ['.napi-locks', '.NAPI-locks/nested']) {
      final reserved = Directory('${root.path}/$name');
      await expectLater(
        assemblePackageSet(
          modules: modules,
          output: reserved,
          metadata: metadata,
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(reserved.existsSync(), isFalse);
    }
    await assemblePackage(modules: modules, output: output, metadata: metadata);
    expect(await OutputOwnership.read(output), isNotNull);
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

  test('npm installs only the selected optional platform and preserves loader errors', () async {
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
  }, timeout: const Timeout(Duration(minutes: 3)));

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
