import 'dart:io';

import 'package:napi/napi.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

const _source = '''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.value)
class Value<T> {
  Value(this.value, {this.optional, this.items = const []});
  final T value;
  final T? optional;
  final List<T> items;
}
@NAPI(classPolicy: ClassPolicy.value)
class Pair<A, B> {
  Pair(this.first, this.second);
  final A first;
  final B second;
}
@NAPI(classPolicy: ClassPolicy.value)
class Node<T> {
  Node(this.value, {this.next});
  final T value;
  final Node<T>? next;
}
@NAPI(classPolicy: ClassPolicy.value, valueFields: {'source': 'value'})
class Parsed<T> {
  Parsed(T source) : value = 23;
  final int value;
}
@NAPI(classPolicy: ClassPolicy.value)
abstract class Projection<T> { T get value; }
@NAPI(classPolicy: ClassPolicy.value)
class Defaults<T> {
  Defaults({this.items = const [], this.values = const {}, this.nullable = const <Null>[null]});
  final List<T> items;
  final Map<String, T> values;
  final List<T?> nullable;
}
class _Projection<T> implements Projection<T> {
  _Projection(this.value);
  final T value;
}
class Concrete<T> { Concrete(this.value); final T value; }
@NAPI(classPolicy: ClassPolicy.value) typedef IntegerValue = Concrete<int>;
@NAPI() Value<T> echo<T>(Value<T> value) => value;
@NAPI() Pair<B, A> reversed<A, B>(Pair<B, A> value) => value;
@NAPI() Pair<T, T> repeated<T>(Pair<T, T> value) => value;
@NAPI() Node<T> recursive<T>(Node<T> value) => value;
@NAPI() Parsed<T> parse<T>(Parsed<T> value) => value;
@NAPI() Projection<T> project<T>(T value) => _Projection(value);
@NAPI() IntegerValue concrete(IntegerValue value) => value;
@NAPI() Defaults<T> defaults<T>(Defaults<T> value) => value;
''';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  late File input;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-opaque-value-');
    addTearDown(() => directory.delete(recursive: true));
    input = await File('${directory.path}/business.dart')
        .writeAsString(_source);
  });
  Future<BindingModule> read() =>
      AnnotationFrontend(packagesPath: packages).read(input.uri);
  Matcher diagnostic(String code) =>
      isA<BindingDiagnostic>().having((e) => e.code, 'code', code);

  test(
    'value parameters project by declaration through each use site',
    () async {
      final module = await read();
      final wasm = lower(validate(module));
      final native = validateNative(module);
      final echo = wasm.functions.singleWhere(
        (f) => f.binding.exportName == 'echo',
      );
      final value = echo.inputs.single as ValueClassConversion;
      expect(value.typescriptType, contains('<T>'));
      expect(value.dartType, 'target.Value<_NapiHostValue>');
      final own = (value.fields.first.conversion as OpaqueConversion).parameter;
      expect(own, echo.binding.typeParameters.single.declaration);
      expect(value.fields[1].optional, isTrue);
      expect(
        value.fields[1].parameter!.presence,
        ParameterPresence.opaqueOptional,
      );
      expect(
        (value.fields.last.conversion as ListConversion).element,
        isA<OpaqueConversion>(),
      );
      final reversed = wasm.functions.singleWhere(
        (f) => f.binding.exportName == 'reversed',
      );
      final pair = reversed.inputs.single as ValueClassConversion;
      expect(pair.typescriptType, contains('<B, A>'));
      expect(
        pair.fields.map(
          (field) => (field.conversion as OpaqueConversion).parameter,
        ),
        reversed.binding.typeParameters.reversed.map((p) => p.declaration),
      );
      final repeated = wasm.functions.singleWhere(
        (f) => f.binding.exportName == 'repeated',
      );
      final repeatedPair = repeated.inputs.single as ValueClassConversion;
      expect(
        repeatedPair.fields.map(
          (field) => (field.conversion as OpaqueConversion).parameter,
        ),
        everyElement(repeated.binding.typeParameters.single.declaration),
      );
      final recursive = wasm.functions.singleWhere(
        (f) => f.binding.exportName == 'recursive',
      );
      final node = recursive.inputs.single as ValueClassConversion;
      final next = node.fields.last.conversion as ValueClassConversion;
      expect(next.nullable, isTrue);
      expect(identical(next.fields.last.conversion, next), isTrue);
      expect(conversionGraph([node]).length, lessThan(8));
      for (final code in [emitDart(wasm), emitNativeDart(native)]) {
        expect(code, contains('target.Value<_NapiHostValue>('));
        expect(code, contains('target.Pair<_NapiHostValue, _NapiHostValue>('));
        expect(code, contains('target.Node<_NapiHostValue>('));
        expect(code, contains('target.IntegerValue('));
        expect(code, isNot(contains('target.Value<dynamic>')));
      }
      expect(emitDeclarations(wasm), emitNativeDeclarations(native));
    },
  );

  test(
    'external value selection keeps the annotated generic schemas',
    () async {
      final module = await read();
      final external = await ExternalFrontend(
        ExternalLibrary([
          for (final binding in module.classes)
            ExternalClass(
              binding.exportName,
              config: NAPI(
                classPolicy: ClassPolicy.value,
                valueFields: binding.exportName == 'Parsed'
                    ? const {'source': 'value'}
                    : const {},
              ),
            ),
          for (final function in module.functions)
            ExternalFunction(function.exportName),
        ]),
        packagesPath: packages,
      ).read(input.uri);
      expect(
        emitDeclarations(lower(validate(external))),
        emitDeclarations(lower(validate(module))),
      );
      expect(
        emitNativeDeclarations(validateNative(external)),
        emitNativeDeclarations(validateNative(module)),
      );
    },
  );

  test('generic value TypeScript keeps directional fields and exact presence', () async {
    final wasm = lower(validate(await read()));
    final declaration = await File('${directory.path}/module.d.ts')
        .writeAsString(emitDeclarations(wasm));
    final consumer = await File('${directory.path}/consumer.ts')
        .writeAsString('''
import {echo, reversed, repeated, recursive, parse, project, concrete, defaults, Value, Pair, Node} from './module.js';
const output: Value<string> = echo<string>({value: 'a', items: ['b']});
const optional: string | null = output.optional;
echo<string>({value: 'a'});
echo<string>({value: 'a', items: [], optional: null});
echo<string | undefined>({value: undefined, items: [], optional: undefined});
// @ts-expect-error exact optional opaque properties require undefined in T
echo<string>({value: 'a', items: [], optional: undefined});
// @ts-expect-error required opaque fields cannot be omitted
echo<string>({});
// @ts-expect-error opaque element types remain precise
echo<string>({value: 'a', items: [1]});
const pair: Pair<number, string> = reversed<string, number>({first: 3, second: 'a'});
const duplicated: Pair<string, string> = repeated<string>({first: 'a', second: 'b'});
// @ts-expect-error use-site argument permutation preserves each field type
reversed<string, number>({first: 'a', second: 3});
const node: Node<string> = recursive<string>({value: 'a', next: {value: 'b'}});
const parsed: number = parse<string>({value: 'a'}).value;
// @ts-expect-error constructor input is independent of its output getter
parse<string>({value: 7});
const projected: string = project('a').value;
const integer: number = concrete({value: 7}).value;
const empty = defaults<string>({});
const emptyItems: string[] = empty.items;
const emptyValues: Map<string, string> = empty.values;
const nullableItems: Array<string | null> = empty.nullable;
// @ts-expect-error output fields remain required
const incomplete: Value<string> = {value: 'a'};
void [optional, pair, duplicated, node, parsed, projected, integer, emptyItems, emptyValues, nullableItems, incomplete];
''');
    final tsc =
        Platform.environment['NAPI_TSC'] ??
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
    final checked = await Process.run(Platform.environment['NODE'] ?? 'node', [
      tsc,
      '--ignoreConfig',
      '--noEmit',
      '--strict',
      '--exactOptionalPropertyTypes',
      '--target',
      'ES2022',
      declaration.path,
      consumer.path,
    ]);
    expect(checked.exitCode, 0, reason: '${checked.stdout}${checked.stderr}');
  });

  for (final (name, body, code) in [
    (
      'nested argument',
      '@NAPI() Value<List<T>> bad<T>(Value<List<T>> value) => value;',
      'NAPI_TYPE',
    ),
    (
      'nullable argument',
      '@NAPI() Value<T?> bad<T>(Value<T?> value) => value;',
      'NAPI_TYPE',
    ),
    (
      'unselected concrete argument',
      '@NAPI() Value<int> bad(Value<int> value) => value;',
      'NAPI_TYPE',
    ),
    (
      'constructorless input',
      '@NAPI() int bad<T>(Projection<T> value) => 1;',
      'NAPI_VALUE_INPUT',
    ),
  ]) {
    test('generic values diagnose $name', () async {
      await input.writeAsString('$_source\n$body');
      final module = await read();
      expect(() => validate(module), throwsA(diagnostic(code)));
      expect(() => validateNative(module), throwsA(diagnostic(code)));
    });
  }
}
