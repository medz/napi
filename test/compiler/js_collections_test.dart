import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/js/boundary.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
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

  test('unused modules emit no collection runtime', () async {
    final module = await read('@NAPI() int add(int a, int b) => a + b;');
    final wasm = lower(validate(module));
    expect(emitDart(wasm), isNot(contains('_jc')));
    expect(emitBoundary(wasm), isNot(contains(r'$jc')));
    expect(emitNativeLoader(['add']), isNot(contains(r'$jc')));
  });

  for (final source in [
    '@NAPI() JsArray<List<int>> bad(JsArray<List<int>> value) => value;',
    '@NAPI() JsMap<Object, int> bad(JsMap<Object, int> value) => value;',
    '@NAPI() List<JsArray<int>> bad(List<JsArray<int>> value) => value;',
    '@NAPI() int bad(JsArray<int> Function() callback) => 0;',
    '@NAPI() JsArray<T> bad<T>(JsArray<T> value) => value;',
    '@NAPI(classPolicy: ClassPolicy.value, valueConstructor: "new") class Packet { Packet(this.items); final JsArray<int> items; } @NAPI() Packet packet(Packet value) => value;',
  ]) {
    test('unsupported payload is diagnostic: $source', () async {
      final module = await read(source);
      for (final validateModule in [validate, validateNative]) {
        expect(() => validateModule(module), throwsA(isA<BindingDiagnostic>()));
      }
    });
  }
}
