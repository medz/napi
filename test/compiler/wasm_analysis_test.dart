import 'dart:convert';
import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

File _write(Directory directory, String name, String source) {
  final file = File('${directory.path}/$name');
  file.parent.createSync(recursive: true);
  return file..writeAsStringSync(source);
}

Matcher _sdkError(String code) => throwsA(
  isA<SdkCompatibilityException>().having((error) => error.code, 'code', code),
);

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  final frontend = AnnotationFrontend(packagesPath: packages);
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-wasm-analysis-');
    addTearDown(() => directory.delete(recursive: true));
  });

  test(
    'preserves int and double aliases and canonical annotation identity',
    () async {
      _write(directory, 'annotations.dart', "export 'package:napi/napi.dart';");
      final source = _write(directory, 'entry.dart', '''
import 'annotations.dart' as canonical;

class NAPI {
  const NAPI();
}

typedef Integer = int;
typedef Decimal = double;

@canonical.NAPI()
Integer integer(Integer value) => value;

@canonical.NAPI()
Decimal decimal(Decimal value) => value;

@NAPI()
int unrelatedAnnotation(int value) => value;
''');
      final module = await frontend.read(source.uri);
      expect(module.functions.map((function) => function.exportName), [
        'integer',
        'decimal',
      ]);
      final integer = module.functions.first;
      expect(integer.result, isA<SafeIntType>());
      expect(integer.parameters.single.type, isA<SafeIntType>());
      expect(integer.result.alias?.declaration.name, 'Integer');
      expect(integer.result.alias?.declaration.library, source.uri);
      expect(integer.parameters.single.type.alias?.declaration.name, 'Integer');

      final decimal = module.functions.last;
      expect(decimal.result, isA<DeclaredType>());
      final type = decimal.result as DeclaredType;
      expect(type.declaration.library, Uri.parse('dart:core'));
      expect(type.declaration.name, 'double');
      expect(type.alias?.declaration.name, 'Decimal');
      expect(decimal.parameters.single.type, isA<DeclaredType>());
    },
  );

  test(
    'conditional exports agree with the real Wasm compiler and safe-int ABI',
    () async {
      final source = _write(directory, 'entry.dart', '''
export 'fallback.dart'
    if (dart.library.io) 'io.dart'
    if (dart.library.ffi) 'ffi.dart'
    if (dart.library.js_interop) 'wasm.dart';
''');
      for (final name in ['fallback', 'io', 'ffi']) {
        _write(directory, '$name.dart', '''
import 'package:napi/napi.dart';
@NAPI()
double selected(double value) => value + 100;
''');
      }
      final wasm = _write(directory, 'wasm.dart', '''
import 'package:napi/napi.dart';
typedef Integer = int;
@NAPI()
Integer selected(Integer value) => value + 7;
''');
      final module = await frontend.read(source.uri);
      final function = module.functions.single;
      expect(function.declaration.library, wasm.uri);
      expect(function.exportSurface, source.uri);
      expect(function.result, isA<SafeIntType>());
      expect(function.parameters.single.type, isA<SafeIntType>());
      expect(function.result.alias?.declaration.name, 'Integer');

      final built = await buildModule(
        bindings: module,
        output: Directory('${directory.path}/output'),
        packagesPath: packages,
      );
      final consumer = _write(directory, 'consumer.mjs', '''
import assert from 'node:assert/strict';
import {selected} from './output/module.wasm';
assert.equal(selected(35), 42);
assert.equal(selected(-8), -1);
assert.throws(() => selected(Number.MAX_SAFE_INTEGER + 1), RangeError);
assert.throws(() => selected(1.5), RangeError);
assert.throws(() => selected('35'), TypeError);
console.log('wasm-platform-selection-ok');
''');
      expect(built.wasm.existsSync(), isTrue);
      final result = await Process.run('node', [consumer.path]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('wasm-platform-selection-ok'));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'unsupported library environment names are absent rather than false',
    () async {
      _write(directory, 'integer.dart', 'typedef Selected = int;');
      _write(directory, 'decimal.dart', 'typedef Selected = double;');
      final source = _write(directory, 'entry.dart', '''
import 'package:napi/napi.dart';
import 'integer.dart'
    if (dart.library.io == 'false') 'decimal.dart'
    if (dart.library.ffi == 'false') 'decimal.dart'
    if (dart.library._wasm) 'decimal.dart';
@NAPI()
Selected selected(Selected value) => value;
''');
      final module = await frontend.read(source.uri);
      expect(module.functions.single.result, isA<SafeIntType>());
    },
  );

  test('rejects an SDK version other than the pinned compiler', () async {
    final source = _write(directory, 'entry.dart', 'void main() {}');
    _write(directory, 'sdk/version', '3.13.6');
    await expectLater(
      AnnotationFrontend(
        sdkPath: '${directory.path}/sdk',
        packagesPath: packages,
      ).read(source.uri),
      _sdkError('NAPI_SDK_VERSION'),
    );
  });

  test('does not expose JavaScript-only SDK libraries', () async {
    for (final library in ['html', 'js_util']) {
      final source = _write(directory, '$library.dart', '''
import 'dart:$library';
import 'package:napi/napi.dart';
@NAPI()
int selected(int value) => value;
''');
      await expectLater(
        frontend.read(source.uri),
        throwsA(
          isA<BindingDiagnostic>().having(
            (error) => error.code,
            'code',
            'NAPI_DART',
          ),
        ),
      );
    }
  });

  test('fails closed on missing, malformed, or cyclic SDK metadata', () async {
    final source = _write(directory, 'entry.dart', 'void main() {}');
    _write(directory, 'sdk/version', supportedDartSdkVersion);
    final sdkFrontend = AnnotationFrontend(
      sdkPath: '${directory.path}/sdk',
      packagesPath: packages,
    );
    for (final metadata in [
      null,
      '{invalid json',
      jsonEncode({
        'wasm': {'libraries': <String, Object?>{}},
      }),
      jsonEncode({
        'wasm': {
          'include': [
            {'target': 'wasm'},
          ],
          'libraries': <String, Object?>{},
        },
      }),
      jsonEncode({
        'wasm': {
          'libraries': {
            'core': {'uri': 'core/core.dart'},
          },
        },
      }),
    ]) {
      if (metadata != null) {
        _write(directory, 'sdk/lib/libraries.json', metadata);
      }
      await expectLater(
        sdkFrontend.read(source.uri),
        _sdkError('NAPI_SDK_LAYOUT'),
        reason: 'Unusable SDK metadata: $metadata',
      );
    }
  });

  test('rejects a package embedder replacing the Wasm SDK', () async {
    final source = _write(directory, 'entry.dart', 'void main() {}');
    _write(directory, 'sky_engine/lib/core.dart', 'library dart.core;');
    _write(directory, 'sky_engine/lib/_embedder.yaml', '''
embedded_libs:
  "dart:core": "core.dart"
''');
    final configuration = _write(
      directory,
      'package_config.json',
      jsonEncode({
        'configVersion': 2,
        'packages': [
          {
            'name': 'sky_engine',
            'rootUri': './sky_engine/',
            'packageUri': 'lib/',
            'languageVersion': '3.13',
          },
        ],
      }),
    );
    await expectLater(
      AnnotationFrontend(packagesPath: configuration.path).read(source.uri),
      _sdkError('NAPI_SDK_LAYOUT'),
    );
  });
}
