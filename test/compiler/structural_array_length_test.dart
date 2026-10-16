import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/js/boundary.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/linker/dart_module_linker.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:test/test.dart';

void main() {
  test(
    'generated array conversions capture and validate length once',
    () async {
      final source = Uri.file('/fixtures/array_length.dart');
      final type = DeclaredType(
        DeclarationId(
          Uri.parse('dart:core'),
          'List',
          kind: DeclarationKind.classType,
        ),
        ValueSemantics.structural,
        typeArguments: [const SafeIntType()],
      );
      final plan = lower(
        validate(
          BindingModule(
            source: source,
            functions: [
              FunctionBinding(
                declaration: DeclarationId(source, 'echo'),
                exportName: 'echo',
                source: SourceLocation(source, 0, 1),
                parameters: [ParameterBinding('value', type)],
                result: type,
              ),
            ],
          ),
        ),
      );
      final directory = await Directory.systemTemp.createTemp(
        'napi-array-length-',
      );
      addTearDown(() => directory.delete(recursive: true));
      await File('${directory.path}/boundary.mjs')
          .writeAsString(emitBoundary(plan));
      await File('${directory.path}/test.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import {readValue, writeValue} from './boundary.mjs';
for (const [convert, path] of [
  [value => readValue(value, 0), 'echo.value'],
  [value => writeValue(value, 1), 'echo result'],
]) {
  let reads = 0;
  const proxy = new Proxy([1, 2], {
    get(target, key, receiver) {
      if (key === 'length') {
        assert.equal(++reads, 1, 'length must not be re-read for keys or loop');
        return 2;
      }
      return Reflect.get(target, key, receiver);
    },
  });
  assert.deepEqual(convert(proxy), [1, 2]);
  assert.equal(reads, 1);
  for (const length of [undefined, null, '2', true, {}, Symbol('length'), 1n,
      NaN, Infinity, -Infinity, -1, 0.5, 0x100000000]) {
    let reads = 0;
    const proxy = new Proxy([], {
      get(target, key, receiver) {
        if (key === 'length') { reads++; return length; }
        return Reflect.get(target, key, receiver);
      },
    });
    assert.throws(() => convert(proxy), error => error instanceof TypeError &&
      error.message === path + '.length: expected an Array length');
    assert.equal(reads, 1);
  }
  const maximum = new Proxy([], {get(target, key) {
    return key === 'length' ? 0xffffffff : Reflect.get(target, key);
  }});
  assert.throws(() => convert(maximum), error => error instanceof RangeError &&
    error.message === path + ': structural work limit (10000) exceeded');
  // Key bounds also use the captured length, before any child descriptor read.
  let descriptors = 0;
  const shortened = new Proxy([1, 2], {
    get(target, key) { return key === 'length' ? 1 : Reflect.get(target, key); },
    getOwnPropertyDescriptor(target, key) {
      descriptors++;
      return Reflect.getOwnPropertyDescriptor(target, key);
    },
  });
  assert.throws(() => convert(shortened), error => error instanceof TypeError &&
    error.message === path + '.1: unknown Array property');
  assert.equal(descriptors, 0);
  assert.deepEqual(convert([3]), [3], 'failure leaves the next conversion usable');
}
''');
      final execution = await Process.run('node', [
        'test.mjs',
      ], workingDirectory: directory.path);
      expect(
        execution.exitCode,
        0,
        reason: '${execution.stdout}${execution.stderr}',
      );
    },
  );
  test(
    'custom Dart List lengths are checked before the output work budget',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'napi-output-length-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final packages = File('.dart_tool/package_config.json').absolute.path;
      final input = await File('${directory.path}/business.dart')
          .writeAsString('''
import 'dart:collection';
import 'package:napi/napi.dart';
class _InvalidList extends ListBase<int> {
  _InvalidList(this.length);
  @override int length;
  @override int operator [](int index) => throw StateError('index must not be read');
  @override void operator []=(int index, int value) => throw UnimplementedError();
}
@NAPI() List<int> invalid(int length) => _InvalidList(length);
''');
      final plan = lower(
        validate(
          await AnnotationFrontend(packagesPath: packages).read(input.uri),
        ),
      );
      final entry = await File('${directory.path}/entry.dart')
          .writeAsString(emitDart(plan));
      final compiled = await DartSdkAdapter().compile(
        sourcePath: entry.path,
        outputPath: '${directory.path}/raw.wasm',
        packagesPath: packages,
      );
      final linked = linkDartModule(
        rawWasmBytes: await File(compiled.wasmPath).readAsBytes(),
        rawMjsText: await File(compiled.jsPath).readAsString(),
        hostSpecifier: './host.mjs',
        coreSpecifier: './core.wasm',
        additionalImports: {'napi': './boundary.mjs'},
      );
      await File('${directory.path}/core.wasm').writeAsBytes(linked.wasmBytes);
      await File('${directory.path}/host.mjs')
          .writeAsString(linked.hostJavaScript);
      await File('${directory.path}/boundary.mjs')
          .writeAsString(emitBoundary(plan));
      await File('${directory.path}/test.mjs').writeAsString('''
import assert from 'node:assert/strict';
import {invalid} from './core.wasm';
for (const length of [-1, 0x100000000]) {
  assert.throws(() => invalid(length), error => error instanceof TypeError &&
    error.message === 'invalid result.length: expected an Array length');
}
assert.throws(() => invalid(10000), error => error instanceof RangeError &&
  error.message === 'invalid result: structural work limit (10000) exceeded');
assert.deepEqual(invalid(0), [], 'failure must not retain active output state');
''');
      final execution = await Process.run('node', [
        'test.mjs',
      ], workingDirectory: directory.path);
      expect(
        execution.exitCode,
        0,
        reason: '${execution.stdout}${execution.stderr}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
