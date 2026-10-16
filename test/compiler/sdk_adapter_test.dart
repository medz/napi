import 'dart:io';

import 'package:napi/src/compiler/linker/dart_module_linker.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:napi/src/compiler/sdk_adapter/host_template.dart';
import 'package:test/test.dart';

void main() {
  test('pins the experimental adapter to the tested stable SDK', () {
    expect(supportedDartSdkVersion, '3.13.5');
    expect(
      () => DartSdkAdapter.verifyVersionOutput(
        'Dart SDK version: 3.13.5 (stable) (build date) on "linux_x64"',
      ),
      returnsNormally,
    );
    // Simulated version output, independent of which SDKs have been released.
    for (final version in [
      'Dart SDK version: 3.13.6 (stable)',
      'Dart SDK version: 3.14.0 (stable)',
      'Dart SDK version: 3.13.5 (dev)',
      'Dart SDK version: 3.13.50 (stable)',
      'not a Dart SDK',
    ]) {
      expect(
        () => DartSdkAdapter.verifyVersionOutput(version),
        throwsA(
          isA<SdkCompatibilityException>().having(
            (error) => error.code,
            'diagnostic',
            'NAPI_SDK_VERSION',
          ),
        ),
      );
    }
  });

  test('pubspec admits exactly the SDK supported by the private adapter', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final sdkConstraint = RegExp(
      r"^  sdk: '([^']+)'$",
      multiLine: true,
    ).firstMatch(pubspec)?.group(1);
    expect(sdkConstraint, supportedDartSdkVersion);
  });

  test('unknown SDK host layout fails closed with a useful diagnostic', () {
    expect(
      () => extractDartHostHelpers('export const unknownLoader = true;'),
      throwsA(
        isA<SdkCompatibilityException>().having(
          (error) => error.code,
          'diagnostic',
          'NAPI_SDK_HOST_LAYOUT',
        ),
      ),
    );
  });

  test('missing compiler helper is diagnosed before output is emitted', () {
    expect(
      () => verifyDartHostImport('    const dart2wasm = {};', 'missing'),
      throwsA(
        isA<SdkCompatibilityException>().having(
          (error) => error.code,
          'diagnostic',
          'NAPI_SDK_HOST_IMPORT',
        ),
      ),
    );
  });

  test(
    'fresh pinned SDK output directly imports and retains Dart state',
    () async {
      final directory = await Directory.systemTemp.createTemp('napi-sdk-');
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/entry.dart');
      await source.writeAsString(r'''
import 'dart:_wasm';
import 'dart:_js_interop_wasm';
import 'dart:js_interop';
int calls = 0;
@pragma('wasm:export', 'add')
WasmI32 add(WasmI32 left, WasmI32 right) =>
    WasmI32.fromInt(left.toIntSigned() + right.toIntSigned() + calls++);
@pragma('wasm:export', 'text')
WasmExternRef? text() => externRefForJSAny('a\ud800b\udfff'.toJS);
void main() => throw StateError('Business main must not run');
''');
      final compilation = await DartSdkAdapter().compile(
        sourcePath: source.path,
        outputPath: '${directory.path}/raw.wasm',
      );
      expect(compilation.version, supportedDartSdkVersion);
      expect(File(compilation.sdkLicensePath).existsSync(), isTrue);
      expect(File('${directory.path}/raw.wasm.map').existsSync(), isFalse);
      final original = await File(compilation.wasmPath).readAsBytes();
      final rawHost = await File(compilation.jsPath).readAsString();
      expect(extractDartStringConstants(rawHost), ['a\ud800b\udfff']);
      for (final table in [
        '      s: [\n        1,\n      ],\n',
        '      s: [\n        (() => "executed")(),\n      ],\n',
        '      s: [\n        "unterminated,\n      ],\n',
        '      s: [\n      ],\n',
        '      s: [\n        "value",\n      ],\n      extra: true,\n',
      ]) {
        final changed = rawHost.replaceFirst(
          RegExp(r'      s: \[\n(?:[^\n]*\n)*?      \],\n'),
          table,
        );
        expect(
          () => extractDartHostHelpers(changed),
          throwsA(
            isA<SdkCompatibilityException>().having(
              (error) => error.code,
              'diagnostic',
              'NAPI_SDK_HOST_LAYOUT',
            ),
          ),
        );
      }
      final linked = linkDartModule(
        rawWasmBytes: original,
        rawMjsText: rawHost,
        hostSpecifier: './host.mjs',
        coreSpecifier: './module.wasm',
      );
      expect(linked.hostJavaScript, isNot(contains('invokeMain(')));
      expect(linked.hostJavaScript, isNot(contains('WebAssembly.instantiate')));
      expect(linked.hostJavaScript, contains('const dartInstance ='));
      await File('${directory.path}/module.wasm')
          .writeAsBytes(linked.wasmBytes);
      await File('${directory.path}/host.mjs')
          .writeAsString(linked.hostJavaScript);
      await File('${directory.path}/consumer.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import {add, text} from './module.wasm';
assert.equal(add(2, 3), 5);
assert.equal(add(2, 3), 6);
assert.equal(text(), 'a\ud800b\udfff');
console.log('direct-sdk-ok');
''');
      final result = await Process.run('node', [
        '${directory.path}/consumer.mjs',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('direct-sdk-ok'));
      // Compiler coupling is checked before producing a linked artifact.
      expect(
        () => linkDartModule(
          rawWasmBytes: original,
          rawMjsText: rawHost.replaceFirst(
            'const baseImports = {',
            'const changedImports = {',
          ),
          hostSpecifier: './host.mjs',
          coreSpecifier: './module.wasm',
        ),
        throwsA(isA<SdkCompatibilityException>()),
      );
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
