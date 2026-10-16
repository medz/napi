import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/js/structural.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:test/test.dart';

final _source = Uri.file('/fixtures/structural.dart');
DeclaredType _list(BindingType element, {bool nullable = false}) =>
    DeclaredType(
      DeclarationId(
        Uri.parse('dart:core'),
        'List',
        kind: DeclarationKind.classType,
      ),
      ValueSemantics.structural,
      typeArguments: [element],
      nullability: nullable
          ? TypeNullability.nullable
          : TypeNullability.nonNullable,
    );

BindingModule _module(BindingType type, {ParameterBinding? parameter}) =>
    BindingModule(
      source: _source,
      functions: [
        FunctionBinding(
          declaration: DeclarationId(_source, 'convert'),
          exportName: 'convert',
          source: SourceLocation(_source, 0, 1),
          parameters: [parameter ?? ParameterBinding('value', type)],
          result: type,
        ),
      ],
    );

/// Deliberately test only the interface: production never selects this adapter
/// for reference, opaque or shared declarations until those engines exist.
final class _IdentityAdapter implements StructuralLeafAdapter {
  @override
  String read(ValueConversion leaf, String value, String path) => value;
  @override
  String write(ValueConversion leaf, String value, String path) => value;
}

void main() {
  test('unsupported structural leaves remain diagnosed', () {
    for (final type in [
      const DynamicType(),
      DeclaredType(DeclarationId(_source, 'Opaque'), ValueSemantics.opaque),
      DeclaredType(
        DeclarationId(_source, 'Reference'),
        ValueSemantics.reference,
      ),
      DeclaredType(DeclarationId(_source, 'Shared'), ValueSemantics.shared),
    ]) {
      expect(
        () => validate(_module(_list(type))),
        throwsA(isA<BindingDiagnostic>()),
      );
    }
  });

  test(
    'null structural defaults work and unresolved const defaults fail closed',
    () {
      final type = _list(const SafeIntType(), nullable: true);
      expect(
        lower(
          validate(
            _module(
              type,
              parameter: ParameterBinding(
                'value',
                type,
                kind: ParameterKind.optionalPositional,
              ),
            ),
          ),
        ).functions.single.inputs.single,
        isA<ListConversion>(),
      );
      expect(
        () => validate(
          _module(
            type,
            parameter: ParameterBinding(
              'value',
              type,
              kind: ParameterKind.optionalPositional,
              defaultSource: 'const <int>[]',
            ),
          ),
        ),
        throwsA(
          isA<BindingDiagnostic>()
              .having((e) => e.code, 'code', 'NAPI_DEFAULT')
              .having(
                (e) => e.message,
                'message',
                contains('Non-null structural defaults'),
              ),
        ),
      );
    },
  );

  test('leaf adapters preserve identity while each structural occurrence is cloned', () async {
    final directory = await Directory.systemTemp.createTemp(
      'napi-structural-adapter-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final record = RecordTypeBinding(named: {'item': const SafeIntType()});
    final conversion = conversionFor(_list(record), 'adapter', bigint: false);
    final emitted = emitStructuralBoundary(
      conversion,
      prefix: 'adapter',
      leafAdapter: _IdentityAdapter(),
    );
    await File('${directory.path}/test.mjs').writeAsString('''
import assert from 'node:assert/strict';
$structuralPolicy
${emitted.source}
const leaf = {identity: 1};
const record = {item: leaf};
const source = [record, record];
const read = ${emitted.read}(source, 'adapter', {work: 0, active: new Set()}, 0);
assert.notEqual(read, source);
assert.notEqual(read[0], read[1]);
assert.equal(read[0][0], leaf);
assert.equal(read[1][0], leaf);
const write = ${emitted.write}(read, 'adapter', {work: 0, active: new Set()}, 0);
assert.notEqual(write, read);
assert.notEqual(write[0], write[1]);
assert.equal(write[0].item, leaf);
assert.equal(write[1].item, leaf);
write[0].extra = 1;
assert.equal(Object.hasOwn(write[1], 'extra'), false);
for (const identity of [undefined, null, () => 1, new Uint8Array(4), Symbol('opaque')]) {
  const nested = [{item: identity}];
  const input = ${emitted.read}(nested, 'adapter', {work: 0, active: new Set()}, 0);
  const output = ${emitted.write}(input, 'adapter', {work: 0, active: new Set()}, 0);
  assert.notEqual(output, nested);
  assert.notEqual(output[0], nested[0]);
  assert.equal(output[0].item, identity);
}
''');
    final result = await Process.run('node', [
      'test.mjs',
    ], workingDirectory: directory.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });
}
