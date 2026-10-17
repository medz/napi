import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:napi/src/build/native_bundle.dart';
import 'package:napi/build.dart';
import 'package:napi/src/compiler/native/loader.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_aot_adapter.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Map<String, Object?> manifest;
  const identity = 'dart-3.13.5-product-macos-arm64-abi15-fixture';
  const runtime = 'libnapi_runtime_$identity.dylib';
  Future<void> save() =>
      File('${root.path}/manifest.json').writeAsString(jsonEncode(manifest));
  setUp(() async {
    root = await Directory.systemTemp.createTemp('napi bundle 中文 ');
    root = Directory(root.resolveSymbolicLinksSync());
    addTearDown(() => root.delete(recursive: true));
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
      'platform': 'macos',
      'architecture': 'arm64',
      'minimumOsVersion': '14.0',
      'abi': 15,
      'identity': identity,
      'bridge': 'bridge.node',
      'runtime': runtime,
      'files': hashes,
    };
    await save();
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
    'native npm assembly retains provenance and fixes target exports',
    () async {
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
      expect(package['os'], ['darwin']);
      expect(package['cpu'], ['arm64']);
      expect((package['exports'] as Map)['.'], {
        'types': './module.d.mts',
        'import': './module.mjs',
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
            'cpu': ['x64'],
          },
        ),
        throwsArgumentError,
      );
      expect(Directory('${root.path}/bad').existsSync(), isFalse);
      await expectLater(
        assembleWasmPackage(
          module: module,
          output: output,
          metadata: {'name': '@napi/fixture', 'version': '0.0.0'},
        ),
        throwsArgumentError,
      );
      await expectLater(
        assembleNativePackage(
          module: module,
          output: output,
          metadata: {'name': '@napi/fixture', 'version': '0.0.0'},
        ),
        throwsArgumentError,
      );
      expect(File('${output.path}/module.aot').readAsStringSync(), 'fixture');
    },
  );
}
