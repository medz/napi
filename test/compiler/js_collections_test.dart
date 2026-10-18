import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/js/boundary.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/loader.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-js-collections-');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<BindingModule> read(String source) async {
    final file = await File('${directory.path}/entry.dart').writeAsString('''
import 'package:napi/napi.dart';
$source
''');
    return AnnotationFrontend(packagesPath: packages).read(file.uri);
  }

  test('canonical handles retain scalar policy and native TS shape', () async {
    final module = await read('''
typedef Numbers = JsArray<int>;
@NAPI() Numbers array(Numbers value) => value;
@NAPI() JsMap<String?, double?> map(JsMap<String?, double?> value) => value;
@NAPI() Future<JsArray<int>> later(JsArray<int> value) async => value;
@NAPI() Stream<JsMap<String, int?>> events(JsMap<String, int?> value) => Stream.value(value);
@NAPI() JsArray<int>? nullable([JsArray<int>? value]) => value;
@NAPI() JsArray<bool> boolean(JsArray<bool> value) => value;
@NAPI(bigint: true) JsArray<bool> sameBoolean(JsArray<bool> value) => value;
@NAPI(bigint: true) JsArray<int> big(JsArray<int> value) => value;
''');
    final wasm = lower(validate(module));
    final native = validateNative(module);
    for (final conversions in [
      wasm.functions.map((f) => f.inputs.single),
      native.functions.map((f) => f.inputs.single),
    ]) {
      final values = conversions.cast<JsCollectionConversion>().toList();
      expect(values[0].dartType, 'napi.JsArray<int>');
      expect(
        values[1].typescriptType,
        'globalThis.Map<string | null, number | null>',
      );
      expect(values[0].signatureKey, values[4].signatureKey);
      expect(values[5].signatureKey, values[6].signatureKey);
      expect(values[0].signatureKey, isNot(values[7].signatureKey));
    }
    for (final text in [
      emitDeclarations(wasm),
      emitNativeDeclarations(native),
    ]) {
      expect(text, contains('globalThis.Array<number>'));
      expect(text, contains('globalThis.Array<bigint>'));
      expect(text, isNot(contains('LiveList')));
      expect(text, isNot(contains('unique symbol')));
    }
  });

  test('copied containers discover terminal handle policies without changing root contexts', () async {
    final module = await read('''
@NAPI() List<JsArray<int>> arrays(List<JsArray<int>> value) => value;
@NAPI() Map<String, JsMap<String, int?>> maps(Map<String, JsMap<String, int?>> value) => value;
@NAPI() Dictionary<JsArray<int>?> dictionary(Dictionary<JsArray<int>?> value) => value;
@NAPI() (JsArray<T>, JsMap<String, T?>) record<T>((JsArray<T>, JsMap<String, T?>) value) => value;
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class Packet { Packet(this.items); final JsArray<int> items; }
@NAPI() Packet packet(Packet value) => value;
''');
    final wasm = lower(validate(module));
    final native = validateNative(module);
    expect(wasm.conversions.whereType<JsCollectionConversion>(), isEmpty);
    expect(
      conversionGraph(wasm.conversions).whereType<JsCollectionConversion>(),
      isNotEmpty,
    );
    final scalarOnly = lower(
      validate(
        BindingModule(
          source: module.source,
          functions: [module.functions.first],
        ),
      ),
    );
    expect(emitDart(scalarOnly), contains('final class _NapiHostValue'));
    final dart = emitDart(wasm);
    final boundary = emitBoundary(wasm);
    expect(dart, contains('final class _NapiHostValue'));
    expect(dart, contains('_jcAdapter<'));
    expect(dart, isNot(contains('external WasmExternRef _boxOpaque')));
    expect(boundary, contains(r'const $jcPolicies ='));
    expect(boundary, contains(r'$jcAdmit(value,'));
    expect(boundary, contains('if (value === false)'));
    expect(boundary, isNot(contains('function boxOpaque')));
    for (final (index, conversion) in wasm.conversions.indexed) {
      expect(boundary, contains('case $index:'));
      expect(conversion, isNot(isA<JsCollectionConversion>()));
    }
    expect(emitDeclarations(wasm), emitNativeDeclarations(native));
    expect(emitDeclarations(wasm), contains('globalThis.Array<T>'));
    expect(native.jsCollections, isNotEmpty);
    expect(emitNativeDart(native), contains('jsCollectionResult'));
  });

  test('unused modules emit no collection runtime', () async {
    final module = await read('@NAPI() int add(int a, int b) => a + b;');
    final wasm = lower(validate(module));
    expect(emitDart(wasm), isNot(contains('_jc')));
    expect(emitBoundary(wasm), isNot(contains(r'$jc')));
    expect(emitNativeLoader(['add']), isNot(contains(r'$jc')));
  });

  test('direct opaque leaves retain raw values and logical TS types', () async {
    final module = await read('''
@NAPI() JsArray<T> array<T>(JsArray<T> value) => value;
@NAPI() JsArray<U> renamed<U>(JsArray<U> value) => value;
@NAPI() JsArray<T?> nullable<T>(JsArray<T?> value) => value;
@NAPI() JsMap<K, V> map<K, V>(JsMap<K, V> value) => value;
@NAPI() JsMap<String, T> mixed<T>(JsMap<String, T> value) => value;
@NAPI() Future<JsArray<T>> later<T>(JsArray<T> value) async => value;
@NAPI() Stream<JsArray<T>> events<T>(JsArray<T> value) => Stream.value(value);
@NAPI() class Holder<T> {
  Holder(this.items);
  JsArray<T> items;
  T? get(int index) => items.get(index);
}
''');
    final wasm = lower(validate(module));
    final native = validateNative(module);
    for (final conversions in [
      wasm.functions.map((f) => f.inputs.single),
      native.functions.map((f) => f.inputs.single),
    ]) {
      final values = conversions.cast<JsCollectionConversion>().toList();
      expect(values[0].value, isA<OpaqueConversion>());
      expect(values[0].dartType, 'napi.JsArray<_NapiHostValue>');
      expect(values[0].signatureKey, values[1].signatureKey);
      expect(values[0].signatureKey, isNot(values[2].signatureKey));
      expect(values[2].value.nullable, isTrue);
      expect(values[3].key, isA<OpaqueConversion>());
      expect(values[4].key, isA<ScalarConversion>());
    }
    expect(emitDeclarations(wasm), emitNativeDeclarations(native));
    expect(emitDeclarations(wasm), contains('globalThis.Array<T>'));
    expect(emitDeclarations(wasm), contains('globalThis.Map<K, V>'));
    expect(
      emitDart(wasm),
      contains('_JsElement<_NapiHostValue>(true, null, null)'),
    );
    expect(emitNativeDart(native), contains('NativeJsElement<_NapiHostValue>'));
    expect(emitBoundary(wasm), contains('"opaque":true'));
  });

  test(
    'Wasm opaque collection access and iteration instantiate and run',
    () async {
      final input = await File('${directory.path}/business.dart')
          .writeAsString('''
import 'package:napi/napi.dart';
@NAPI() V first<K,V>(JsMap<K,V> map) => map.entries.first.\$2;
@NAPI() T? get<T>(JsArray<T> array) => array.get(0);
@NAPI() int scalar(JsMap<String,int> map) => map.entries.first.\$2;
''');
      await buildLibrary(
        library: input.uri,
        output: Directory('${directory.path}/module'),
        packagesPath: packages,
      );
      await File('${directory.path}/check.mjs').writeAsString('''
import assert from 'node:assert/strict';
import * as api from './module/module.wasm';
const object = {};
assert.equal(api.first(new Map([[null, undefined]])), undefined);
assert.equal(api.first(new Map([[undefined, object]])), object);
assert.equal(api.get([undefined]), undefined);
assert.equal(api.get([]), null);
assert.equal(api.scalar(new Map([['a', 7]])), 7);
''');
      final result = await Process.run('node', [
        'check.mjs',
      ], workingDirectory: directory.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final source in [
    '@NAPI() JsArray<List<int>> bad(JsArray<List<int>> value) => value;',
    '@NAPI() JsMap<Object, int> bad(JsMap<Object, int> value) => value;',
    '@NAPI() Map<JsArray<int>, int> bad(Map<JsArray<int>, int> value) => value;',
    '@NAPI() Map<(JsMap<String,int>,), int> bad(Map<(JsMap<String,int>,), int> value) => value;',
    '@NAPI() List<JsArray<List<int>>> bad(List<JsArray<List<int>>> value) => value;',
    '@NAPI() JsArray<List<T>> bad<T>(JsArray<List<T>> value) => value;',
    '@NAPI() JsArray<JsArray<T>> bad<T>(JsArray<JsArray<T>> value) => value;',
    '@NAPI() class Value {} @NAPI() JsArray<Value> bad(JsArray<Value> value) => value;',
    '@NAPI(classPolicy: ClassPolicy.resource, cleanup: "close") class Resource { void close() {} } @NAPI() JsArray<Resource> bad(JsArray<Resource> value) => value;',
    '@NAPI() JsArray<Future<T>> bad<T>(JsArray<Future<T>> value) => value;',
    '@NAPI() JsArray<Stream<T>> bad<T>(JsArray<Stream<T>> value) => value;',
    '@NAPI(classPolicy: ClassPolicy.value, valueConstructor: "new") class Packet { Packet(this.items); final JsArray<int> items; } @NAPI() Map<Packet,int> bad(Map<Packet,int> value) => value;',
    '@NAPI(classPolicy: ClassPolicy.value, valueConstructor: "new") class Packet { Packet(this.items); final JsArray<int> items; } @NAPI() (Packet, Map<Packet,int>) bad((Packet, Map<Packet,int>) value) => value;',
  ]) {
    test('unsupported payload is diagnostic: $source', () async {
      final module = await read(source);
      for (final validateModule in [validate, validateNative]) {
        expect(() => validateModule(module), throwsA(isA<BindingDiagnostic>()));
      }
    });
  }
}
