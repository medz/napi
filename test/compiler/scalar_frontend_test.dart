import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:test/test.dart';

final _frontend = AnnotationFrontend(
  packagesPath: File('.dart_tool/package_config.json').absolute.path,
);

Future<BindingModule> _read(String source) async {
  final directory = await Directory.systemTemp.createTemp('napi-scalars-');
  addTearDown(() => directory.delete(recursive: true));
  final file = File('${directory.path}/entry.dart');
  await file.writeAsString("import 'package:napi/napi.dart';\n$source\n");
  return _frontend.read(file.uri);
}

void main() {
  test('preserves core scalar identity, aliases, and nullability', () async {
    final module = await _read('''
typedef Text = String;
typedef Integer = int;
typedef ArbitraryInteger = BigInt;
@NAPI() bool booleanValue(bool value) => value;
@NAPI() String stringValue(String value) => value;
@NAPI() double doubleValue(double value) => value;
@NAPI() BigInt bigIntValue(BigInt value) => value;
@NAPI() int intValue(int value) => value;
@NAPI() bool? nullableBool(bool? value) => value;
@NAPI() String? nullableString(String? value) => value;
@NAPI() double? nullableDouble(double? value) => value;
@NAPI() BigInt? nullableBigInt(BigInt? value) => value;
@NAPI() int? nullableInt(int? value) => value;
@NAPI() Text? textAlias(Text? value) => value;
@NAPI() Integer? intAlias(Integer? value) => value;
@NAPI() ArbitraryInteger? bigIntAlias(ArbitraryInteger? value) => value;
''');
    expect(validate(module).bindings, same(module));
    final functions = {for (final f in module.functions) f.callPath: f};
    for (final (name, coreType) in [
      ('booleanValue', 'bool'),
      ('stringValue', 'String'),
      ('doubleValue', 'double'),
      ('bigIntValue', 'BigInt'),
      ('nullableBool', 'bool'),
      ('nullableString', 'String'),
      ('nullableDouble', 'double'),
      ('nullableBigInt', 'BigInt'),
      ('textAlias', 'String'),
      ('bigIntAlias', 'BigInt'),
    ]) {
      final function = functions[name]!;
      expect(function.bigint, isFalse);
      for (final type in [function.result, function.parameters.single.type]) {
        final declared = type as DeclaredType;
        expect(
          declared.declaration,
          DeclarationId(
            Uri.parse('dart:core'),
            coreType,
            kind: DeclarationKind.classType,
          ),
        );
        expect(declared.semantics, ValueSemantics.scalar);
        expect(declared.typeArguments, isEmpty);
        expect(
          declared.nullability,
          name.startsWith('nullable') || name.endsWith('Alias')
              ? TypeNullability.nullable
              : TypeNullability.nonNullable,
        );
      }
    }
    for (final name in ['intValue', 'nullableInt', 'intAlias']) {
      final function = functions[name]!;
      expect(function.bigint, isFalse);
      for (final type in [function.result, function.parameters.single.type]) {
        expect(type, isA<SafeIntType>());
        expect(
          type.nullability,
          name == 'intValue'
              ? TypeNullability.nonNullable
              : TypeNullability.nullable,
        );
      }
    }
    expect(functions['textAlias']!.result.alias!.declaration.name, 'Text');
    expect(functions['intAlias']!.result.alias!.declaration.name, 'Integer');
    expect(
      functions['bigIntAlias']!.result.alias!.declaration.name,
      'ArbitraryInteger',
    );
  });

  test(
    'records a constant function-level bigint policy independently of type',
    () async {
      final module = await _read('''
const useBigint = true;
typedef Selected = NAPI;
typedef Count = int;
@Selected(name: 'wide', bigint: useBigint)
Count? integerValue(Count? value, int other) => value;
@NAPI(bigint: false) int numberValue(int value) => value;
@NAPI(bigint: true) String textValue(String value) => value;
''');
      expect(validate(module).bindings, same(module));
      expect(module.functions.map((f) => f.bigint), [true, false, true]);
      final integer = module.functions.first;
      expect(integer.exportName, 'wide');
      expect(integer.result, isA<SafeIntType>());
      expect(integer.result.nullability, TypeNullability.nullable);
      expect(integer.result.alias!.declaration.name, 'Count');
      expect(
        integer.parameters.map((p) => p.type),
        everyElement(isA<SafeIntType>()),
      );
      expect(module.functions.last.result, isA<DeclaredType>());
    },
  );

  test('a local BigInt lookalike is not a core scalar', () async {
    final module = await _read('''
class BigInt {}
@NAPI() BigInt value(BigInt value) => value;
''');
    final result = module.functions.single.result as DeclaredType;
    expect(result.declaration.library, module.source);
    expect(result.semantics, ValueSemantics.reference);
    expect(
      () => validate(module),
      throwsA(
        isA<BindingDiagnostic>().having((e) => e.code, 'code', 'NAPI_TYPE'),
      ),
    );
  });

  for (final enabled in [true, false]) {
    for (final (label, declaration, code) in [
      ('class', '@NAPI(bigint: $enabled) class Value {}', 'NAPI_PLACEMENT'),
      (
        'member',
        '@NAPI() class Value { @NAPI(bigint: $enabled) int read() => 0; }',
        'NAPI_PLACEMENT',
      ),
      (
        'excluded member',
        '@NAPI() class Value { @NAPI(exclude: true, bigint: $enabled) int read() => 0; }',
        'NAPI_SELECTION',
      ),
    ]) {
      test('rejects bigint: $enabled on a $label', () async {
        await expectLater(
          _read(declaration),
          throwsA(
            isA<BindingDiagnostic>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.source?.line, 'source line', 2),
          ),
        );
      });
    }
  }
}
