import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:napi/src/build/build.dart' as builder;
import 'package:napi/src/build/native_bundle.dart';
import 'package:napi/src/build/metadata.dart';
import 'package:napi/src/build/output_ownership.dart';
import 'package:napi/src/build/publish.dart' show checkPackageRebuildFilesystem;
import 'package:napi/build.dart';
import 'package:napi/src/compiler/native/loader.dart';
import 'package:napi/src/compiler/native/platform.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_aot_adapter.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

void main() {
  String? unsupportedRebuild;
  try {
    checkPackageRebuildFilesystem(Directory.systemTemp);
  } on UnsupportedError catch (error) {
    unsupportedRebuild = error.toString();
  }
  late Directory root;
  late Map<String, Object?> manifest;
  const identity = 'dart-3.13.5-product-macos-arm64-abi15-fixture';
  const runtime = 'libnapi_runtime_$identity.dylib';
  Future<void> save() =>
      File('${root.path}/manifest.json').writeAsString(jsonEncode(manifest));
  Future<void> selectPlatform(NativePlatform profile) async {
    final identity =
        'dart-3.13.5-product-${profile.platform}-${profile.architecture}-abi15-fixture';
    final runtime = 'libnapi_runtime_$identity.${profile.runtimeExtension}';
    final hashes = <String, String>{};
    for (final name in [
      'bridge.node',
      runtime,
      'DART_LICENSE',
      'DART_AUTHORS',
      'NAPI_LICENSE',
    ]) {
      final bytes = utf8.encode('fixture $name');
      await File('${root.path}/$name').writeAsBytes(bytes);
      hashes[name] = sha256.convert(bytes).toString();
    }
    manifest = {
      'format': 1,
      'sdkVersion': '3.13.5',
      'sdkRevision': nativeSdkRevision,
      'platform': profile.platform,
      'architecture': profile.architecture,
      if (profile.minimumOsVersion != null)
        'minimumOsVersion': profile.minimumOsVersion,
      if (profile.libc != null) 'libc': profile.libc,
      if (profile.minimumLibcVersion != null)
        'minimumLibcVersion': profile.minimumLibcVersion,
      'abi': 15,
      'identity': identity,
      'bridge': 'bridge.node',
      'runtime': runtime,
      'files': hashes,
    };
    await save();
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('napi bundle 中文 ');
    root = Directory(root.resolveSymbolicLinksSync());
    addTearDown(() => root.delete(recursive: true));
    await selectPlatform(NativePlatform.macosArm64);
  });

  test(
    'Linux bundles validate and copy without loading their native code',
    () async {
      await selectPlatform(NativePlatform.linuxX64);
      final bundle = await NativeRuntimeBundle.read(root);
      expect(bundle.platform, NativePlatform.linuxX64);
      expect(bundle.runtime, endsWith('.so'));
      final output = await Directory('${root.path}/copied').create();
      await bundle.copyTo(output);
      expect(
        (await NativeRuntimeBundle.read(output, built: true)).platform,
        NativePlatform.linuxX64,
      );
      expect(File('${output.path}/$runtime').existsSync(), isFalse);
      if (Platform.isMacOS && Abi.current() == Abi.macosArm64) {
        expect(bundle.verifyHost, throwsA(isA<SdkCompatibilityException>()));
      } else if (Platform.isLinux && Abi.current() == Abi.linuxX64) {
        bundle.verifyHost();
      }
    },
  );

  test(
    'host verification rejects a bundle for another architecture or OS',
    () async {
      final bundle = await NativeRuntimeBundle.read(root);
      if (Platform.isMacOS && Abi.current() == Abi.macosArm64) {
        bundle.verifyHost();
      } else {
        expect(bundle.verifyHost, throwsA(isA<SdkCompatibilityException>()));
      }
    },
  );

  test(
    'Linux libc requirements are distinct from the operating system version',
    () async {
      await selectPlatform(NativePlatform.linuxX64);
      for (final change in [
        {'libc': 'musl'},
        {'libc': null},
        {'minimumLibcVersion': '2.9'},
        {'minimumLibcVersion': null},
        {'minimumOsVersion': '2.28'},
      ]) {
        final original = Map<String, Object?>.of(manifest);
        manifest.addAll(change);
        await save();
        await expectLater(
          NativeRuntimeBundle.read(root),
          throwsA(isA<SdkCompatibilityException>()),
        );
        manifest = original;
      }
      manifest['runtime'] = '${manifest['runtime']}.dylib';
      await save();
      await expectLater(NativeRuntimeBundle.read(root), throwsFormatException);
    },
  );

  test('libc versions compare numeric components', () {
    for (final version in ['2.17', '2.17.0', '2.18', '2.40', '3.0']) {
      expect(nativeVersionAtLeast(version, '2.17'), isTrue, reason: version);
    }
    for (final version in ['2.9', '2.16.99', '1.99', '', 'glibc 2.40', '2.x']) {
      expect(nativeVersionAtLeast(version, '2.17'), isFalse, reason: version);
    }
  });

  test('hashes and copies only the declared flat runtime assets', () async {
    await File('${root.path}/unrelated.secret').writeAsString('do not copy');
    final bundle = await NativeRuntimeBundle.read(root);
    final output = await Directory('${root.path}/copied').create();
    await bundle.copyTo(output);
    expect(File('${output.path}/unrelated.secret').existsSync(), isFalse);
    expect(
      await NativeRuntimeBundle.read(output, built: true),
      isA<NativeRuntimeBundle>(),
    );
  });

  test('locked manifest rejects self-consistent metadata changes', () async {
    final expected = sha256
        .convert(await File('${root.path}/manifest.json').readAsBytes())
        .toString();
    await NativeRuntimeBundle.read(root, expectedManifestSha256: expected);
    manifest['build'] = {'note': 'changed metadata'};
    await save();
    await NativeRuntimeBundle.read(root);
    await expectLater(
      NativeRuntimeBundle.read(root, expectedManifestSha256: expected),
      throwsFormatException,
    );
  });

  test(
    'loader public aliases cannot shadow imported or global names',
    () async {
      final file = File('${root.path}/module.mjs');
      await file.writeAsString(
        emitNativeLoader([
          'bindings',
          'require',
          'createRequire',
          'fileURLToPath',
          'globalThis',
          'process',
          'URL',
          'Error',
        ]),
      );
      final result = await Process.run('node', ['--check', file.path]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
  );

  test('rejects a runtime without bulk binary slots before copying', () async {
    manifest['abi'] = 14;
    await save();
    await expectLater(
      NativeRuntimeBundle.read(root),
      throwsA(isA<SdkCompatibilityException>()),
    );
  });

  test('rejects runtime or bridge changes before and during copying', () async {
    final bundle = await NativeRuntimeBundle.read(root);
    await File('${root.path}/bridge.node').writeAsString('different binary');
    await expectLater(NativeRuntimeBundle.read(root), throwsFormatException);
    final output = await Directory('${root.path}/copied').create();
    await expectLater(bundle.copyTo(output), throwsFormatException);
  });

  test(
    'rejects mismatched SDK revision, ABI, target and runtime identity',
    () async {
      for (final field in [
        'sdkVersion',
        'sdkRevision',
        'abi',
        'platform',
        'architecture',
        'minimumOsVersion',
      ]) {
        final before = manifest[field];
        manifest[field] = 'mismatch';
        await save();
        await expectLater(
          NativeRuntimeBundle.read(root),
          throwsA(isA<SdkCompatibilityException>()),
        );
        manifest[field] = before;
      }
      manifest['runtime'] = 'other.dylib';
      await save();
      await expectLater(NativeRuntimeBundle.read(root), throwsFormatException);
    },
  );

  test('rejects missing, extra and traversing manifest paths', () async {
    final files = manifest['files']! as Map<String, String>;
    files['../outside'] = files.remove('bridge.node')!;
    await save();
    await expectLater(NativeRuntimeBundle.read(root), throwsFormatException);
  });

  test('rejects symlink assets', () async {
    if (Platform.isWindows) return;
    final bridge = File('${root.path}/bridge.node');
    await bridge.rename('${root.path}/original.node');
    await Link(bridge.path).create('${root.path}/original.node');
    await expectLater(NativeRuntimeBundle.read(root), throwsArgumentError);
  });

  test(
    'native build rejects source and output before acquiring a runtime',
    () async {
      final source = await File('${root.path}/business.dart').writeAsString('''
import 'package:napi/napi.dart';
@NAPI() int value() => 1;
''');
      final bindings = await builder.readLibraryBindings(
        library: source.uri,
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
        target: BuildTarget.native,
      );
      final output = await Directory('${root.path}/output').create();
      final keep = await File('${output.path}/keep').writeAsString('author');
      await HttpOverrides.runZoned(
        () async {
          await expectLater(
            builder.buildModule(
              bindings: bindings,
              output: output,
              target: BuildTarget.native,
            ),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.message,
                'message',
                contains('Output already exists'),
              ),
            ),
          );
          expect(await keep.readAsString(), 'author');
          await source.delete();
          final absent = Directory('${root.path}/absent/package');
          await expectLater(
            builder.buildModule(
              bindings: bindings,
              output: absent,
              target: BuildTarget.native,
            ),
            throwsA(
              isA<ArgumentError>().having(
                (e) => e.message,
                'message',
                contains('Source library does not exist'),
              ),
            ),
          );
          expect(await absent.parent.exists(), isFalse);
        },
        createHttpClient: (_) =>
            throw StateError('Unexpected runtime download'),
      );
    },
  );

  test(
    'explicit native runtime reaches the compiler without network access',
    () async {
      final source = await File('${root.path}/business.dart').writeAsString('''
import 'package:napi/napi.dart';
@NAPI() int value() => 1;
''');
      final bindings = await builder.readLibraryBindings(
        library: source.uri,
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
        target: BuildTarget.native,
      );
      final work = await Directory(
        await Directory.systemTemp.resolveSymbolicLinks(),
      ).createTemp('napi offline override ');
      addTearDown(() => work.delete(recursive: true));
      final output = Directory('${work.path}/module');
      await HttpOverrides.runZoned(
        () async {
          await expectLater(
            builder.buildModule(
              bindings: bindings,
              output: output,
              target: BuildTarget.native,
              nativeRuntime: root,
              sdk: DartSdkAdapter(executable: '${root.path}/missing-dart'),
            ),
            throwsA(isA<ProcessException>()),
          );
        },
        createHttpClient: (_) =>
            throw StateError('Unexpected runtime download'),
      );
      expect(
        await work.list().length,
        0,
        reason:
            'Compiler failure preserves the absent output and removes staging.',
      );
    },
    skip: !Platform.isMacOS || Abi.current() != Abi.macosArm64,
  );

  for (final profile in NativePlatform.values) {
    test(
      'native npm assembly retains ${profile.name} provenance and target exports',
      () async {
        await selectPlatform(profile);
        final bundle = await NativeRuntimeBundle.read(root);
        final built = await Directory('${root.path}/built').create();
        await bundle.copyTo(built);
        for (final name in ['module.mjs', 'module.d.mts', 'module.aot']) {
          await File('${built.path}/$name').writeAsString('fixture');
        }
        final module = BuiltModule(built, '3.13.5', target: BuildTarget.native);
        final output = Directory('${root.path}/npm');
        await assembleNativePackage(
          module: module,
          output: output,
          metadata: {
            'name': '@napi/fixture',
            'version': '0.0.0',
            'author': 'Author',
          },
        );
        final package = jsonDecode(
          await File('${output.path}/package.json').readAsString(),
        ) as Map;
        expect(package['author'], 'Author');
        expect(package['os'], [profile.nodePlatform]);
        expect(package['cpu'], [profile.architecture]);
        expect(package['libc'], profile.libc == null ? null : [profile.libc]);
        expect((package['exports'] as Map)['.'], {
          'types': './module.d.mts',
          'import': './module.mjs',
          'require': './module.mjs',
        });
        expect(
          File('${output.path}/runtime.json').readAsStringSync(),
          File('${built.path}/runtime.json').readAsStringSync(),
        );
        await expectLater(
          assembleNativePackage(
            module: module,
            output: Directory('${root.path}/bad'),
            metadata: {
              'name': '@napi/fixture',
              'version': '0.0.0',
              'cpu': [profile.architecture == 'arm64' ? 'x64' : 'arm64'],
            },
          ),
          throwsArgumentError,
        );
        expect(Directory('${root.path}/bad').existsSync(), isFalse);
        await expectLater(
          assembleNativePackage(
            module: module,
            output: Directory('${root.path}/bad-libc'),
            metadata: {
              'name': '@napi/fixture',
              'version': '0.0.0',
              'libc': ['musl'],
            },
          ),
          throwsArgumentError,
        );
        expect(Directory('${root.path}/bad-libc').existsSync(), isFalse);
        await expectLater(
          assembleWasmPackage(
            module: module,
            output: output,
            metadata: {'name': '@napi/fixture', 'version': '0.0.0'},
          ),
          throwsArgumentError,
        );
        final rebuild = assembleNativePackage(
          module: module,
          output: output,
          metadata: {'name': '@napi/fixture', 'version': '0.0.0'},
        );
        if (unsupportedRebuild == null) {
          await rebuild;
        } else {
          await expectLater(rebuild, throwsUnsupportedError);
        }
        expect(File('${output.path}/module.aot').readAsStringSync(), 'fixture');
      },
    );

    for (final explicit in [false, true]) {
      test(
        '${profile.name} ${explicit ? 'author' : 'automatic'} platform fields across target changes',
        () async {
          await selectPlatform(profile);
          final bundle = await NativeRuntimeBundle.read(root);
          final built = await Directory('${root.path}/built').create();
          await bundle.copyTo(built);
          for (final name in ['module.mjs', 'module.d.mts', 'module.aot']) {
            await File('${built.path}/$name').writeAsString('fixture');
          }
          final module = BuiltModule(
            built,
            '3.13.5',
            target: BuildTarget.native,
          );
          final output = Directory('${root.path}/npm');
          await assembleNativePackage(
            module: module,
            output: output,
            metadata: {
              'name': '@napi/fixture',
              'version': '0.0.0',
              if (explicit) 'os': [profile.nodePlatform],
              if (explicit) 'cpu': [profile.architecture],
              if (explicit && profile.libc != null) 'libc': [profile.libc],
            },
          );
          final ownership = (await OutputOwnership.read(output))!;
          // Dual assembly and single Wasm assembly both use this author metadata
          // without a native profile. Implicit restrictions must not survive.
          final dual = packageMetadata(ownership.metadata);
          expect(dual.containsKey('os'), explicit);
          expect(dual.containsKey('cpu'), explicit);
          expect(dual.containsKey('libc'), explicit && profile.libc != null);
          final wasm = await Directory('${root.path}/wasm').create();
          for (final name in wasmPackageFiles) {
            await File('${wasm.path}/$name').writeAsString('wasm $name');
          }
          await assembleWasmPackage(
            module: BuiltModule(wasm, '3.13.5'),
            output: output,
            metadata: {'name': '@napi/fixture', 'version': '0.0.1'},
          );
          final package = jsonDecode(
            await File('${output.path}/package.json').readAsString(),
          ) as Map;
          expect(package.containsKey('os'), explicit);
          expect(package.containsKey('cpu'), explicit);
          expect(package.containsKey('libc'), explicit && profile.libc != null);
          if (explicit) {
            expect(package['os'], [profile.nodePlatform]);
            expect(package['cpu'], [profile.architecture]);
            expect(
              package['libc'],
              profile.libc == null ? null : [profile.libc],
            );
          }
          expect(await File('${output.path}/module.aot').exists(), isFalse);
          expect(
            await File('${output.path}/${bundle.runtime}').exists(),
            isFalse,
          );
          expect(
            await File('${output.path}/module.wasm').readAsString(),
            'wasm module.wasm',
          );
          await OutputOwnership.read(output);
        },
        skip: unsupportedRebuild ?? false,
      );
    }
  }
}
