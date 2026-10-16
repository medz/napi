import 'package:napi/src/api/annotation.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:test/test.dart';

final _source = Uri.file('/fixtures/scalars.dart');
final _core = Uri.parse('dart:core');

FunctionBinding _function({
  BindingType result = const SafeIntType(),
  Iterable<ParameterBinding> parameters = const [],
  bool bigint = false,
}) => FunctionBinding(
  declaration: DeclarationId(_source, 'identity'),
  exportName: 'identity',
  source: SourceLocation(_source, 10, 8),
  result: result,
  parameters: parameters,
  bigint: bigint,
);

BindingModule _module(FunctionBinding function) =>
    BindingModule(source: _source, functions: [function]);

DeclaredType _declared(
  String name, {
  Uri? library,
  DeclarationKind kind = DeclarationKind.classType,
  DeclarationId? owner,
  ValueSemantics semantics = ValueSemantics.scalar,
  Iterable<BindingType> arguments = const [],
  TypeNullability nullability = TypeNullability.nonNullable,
}) => DeclaredType(
  DeclarationId(library ?? _core, name, kind: kind, owner: owner),
  semantics,
  typeArguments: arguments,
  nullability: nullability,
);

void main() {
  test('bigint policy defaults to false and can be selected explicitly', () {
    expect(const NAPI().bigint, isFalse);
    expect(const NAPI(bigint: true).bigint, isTrue);
    expect(_function().bigint, isFalse);
    expect(_function(bigint: true).bigint, isTrue);
  });

  test(
    'accepts all scalar parameter and result types with either int policy',
    () {
      for (final nullable in [
        TypeNullability.nonNullable,
        TypeNullability.nullable,
      ]) {
        for (final type in [
          SafeIntType(nullability: nullable),
          for (final name in ['bool', 'String', 'double', 'BigInt'])
            _declared(name, nullability: nullable),
        ]) {
          for (final bigint in [false, true]) {
            final module = _module(
              _function(
                result: type,
                parameters: [ParameterBinding('value', type)],
                bigint: bigint,
              ),
            );
            expect(validate(module).bindings, same(module));
          }
        }
      }
    },
  );

  test(
    'rejects unsupported types and forged scalar metadata in both positions',
    () {
      final unsupported = <BindingType>[
        const DynamicType(),
        const VoidType(),
        const NeverType(),
        const SafeIntType(nullability: TypeNullability.legacy),
        _declared('String', nullability: TypeNullability.legacy),
        _declared('num'),
        _declared('Object'),
        _declared('Null'),
        _declared('String', library: _source),
        _declared('BigInt', library: _source),
        _declared('String', kind: DeclarationKind.enumType),
        _declared('BigInt', owner: DeclarationId(_core, 'Owner')),
        _declared('String', arguments: [const SafeIntType()]),
        _declared('String', semantics: ValueSemantics.reference),
        RecordTypeBinding(positional: [const DynamicType()]),
        FunctionTypeBinding(result: const SafeIntType(), parameters: const []),
      ];
      for (final type in unsupported) {
        for (final binding in [
          _function(result: type),
          _function(parameters: [ParameterBinding('value', type)]),
        ]) {
          expect(
            () => validate(_module(binding)),
            throwsA(
              isA<BindingDiagnostic>()
                  .having((e) => e.code, 'code', 'NAPI_TYPE')
                  .having((e) => e.source?.offset, 'source offset', 10),
            ),
          );
        }
      }
    },
  );
}
