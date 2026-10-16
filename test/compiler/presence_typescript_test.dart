import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:test/test.dart';

final _source = Uri.file('/fixtures/presence.dart');
const _nullableInt = SafeIntType(nullability: TypeNullability.nullable);

String _declarations(
  List<ParameterBinding> parameters, {
  bool bigint = false,
}) => emitDeclarations(
  lower(
    validate(
      BindingModule(
        source: _source,
        functions: [
          FunctionBinding(
            declaration: DeclarationId(_source, 'run'),
            exportName: 'run',
            source: SourceLocation(_source, 0, 3),
            parameters: parameters,
            result: const SafeIntType(),
            bigint: bigint,
          ),
        ],
      ),
    ),
  ),
);

void main() {
  test('required positional functions retain their native declaration', () {
    expect(
      _declarations([const ParameterBinding('value', _nullableInt)]),
      contains('export declare function run(value: number | null): number;'),
    );
  });

  test('optional positional callables expose optional arguments', () {
    expect(
      _declarations([
        const ParameterBinding('first', SafeIntType()),
        const ParameterBinding(
          'second',
          _nullableInt,
          kind: ParameterKind.optionalPositional,
        ),
      ]),
      contains(
        'export declare const run: (first: number, second?: number | null) => number;',
      ),
    );
  });

  test('all optional named fields make the options argument optional', () {
    expect(
      _declarations([
        const ParameterBinding('first', SafeIntType()),
        const ParameterBinding(
          'value',
          _nullableInt,
          kind: ParameterKind.optionalNamed,
        ),
      ]),
      contains(
        'export declare const run: (first: number, options?: { value?: number | null | undefined }) => number;',
      ),
    );
  });

  test('required named fields require options and preserve nullability', () {
    expect(
      _declarations([
        const ParameterBinding(
          'requiredValue',
          _nullableInt,
          kind: ParameterKind.requiredNamed,
        ),
        const ParameterBinding(
          'optionalValue',
          _nullableInt,
          kind: ParameterKind.optionalNamed,
        ),
      ], bigint: true),
      contains(
        'export declare const run: (options: { requiredValue: bigint | null; optionalValue?: bigint | null | undefined }) => bigint;',
      ),
    );
  });

  test('synthetic identifiers avoid positional names and wildcards', () {
    expect(
      _declarations([
        const ParameterBinding('options', SafeIntType()),
        const ParameterBinding('options1', SafeIntType()),
        const ParameterBinding('_', SafeIntType()),
        const ParameterBinding('arg0', SafeIntType()),
        const ParameterBinding('_', SafeIntType()),
        const ParameterBinding(
          'value',
          _nullableInt,
          kind: ParameterKind.optionalNamed,
        ),
      ]),
      contains(
        'export declare const run: (options: number, options1: number, arg1: number, arg0: number, arg2: number, options2?: { value?: number | null | undefined }) => number;',
      ),
    );
  });
}
