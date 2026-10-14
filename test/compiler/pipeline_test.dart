import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/js/boundary.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:test/test.dart';

final source = Uri.file('/fixtures/scalars.dart');
FunctionBinding function({
  String name = 'add',
  String? export,
  BindingType type = const SafeIntType(),
  ParameterPresence presence = ParameterPresence.required,
}) => FunctionBinding(
  declaration: DeclarationId(source, name),
  exportName: export ?? name,
  source: SourceLocation(source, 10, 3),
  parameters: [ParameterBinding('value', type, presence: presence)],
  result: const SafeIntType(),
);
BindingModule module(Iterable<FunctionBinding> functions) =>
    BindingModule(source: source, functions: functions);

void main() {
  test('declaration identity does not depend on an analyzer session', () {
    expect(DeclarationId(source, 'add'), DeclarationId(source, 'add'));
    expect(
      DeclarationId(source, 'add').hashCode,
      DeclarationId(source, 'add').hashCode,
    );
  });
  test('IR freezes input collections', () {
    final functions = [function()];
    final input = module(functions);
    functions.clear();
    expect(input.functions, hasLength(1));
    expect(() => input.functions.clear(), throwsUnsupportedError);
  });
  test(
    'safe int lowering drives all emitters with native externref inputs',
    () {
      final plan = lower(validate(module([function()])));
      expect(
        plan.functions.single.representation,
        ExportRepresentation.nativeFunction,
      );
      expect(emitDart(plan), contains('WasmExternRef? p0'));
      expect(emitDart(plan), contains('_readInt(p0, WasmI32.fromInt(0))'));
      expect(emitBoundary(plan), contains('Number.isSafeInteger'));
      expect(emitDeclarations(plan), contains('add(value: number): number'));
    },
  );
  test('diagnostics retain original source and reject duplicates', () {
    expect(
      () => validate(module([function(), function()])),
      throwsA(
        isA<BindingDiagnostic>()
            .having((e) => e.code, 'code', 'NAPI_DUPLICATE')
            .having((e) => e.source?.offset, 'source offset', 10),
      ),
    );
  });
  test('then export is rejected before ESM thenable assimilation', () {
    expect(
      () => validate(module([function(export: 'then')])),
      throwsA(isA<BindingDiagnostic>()),
    );
  });
  test('unsupported presence never silently becomes fixed arity', () {
    for (final presence in ParameterPresence.values.skip(1)) {
      expect(
        () => validate(module([function(presence: presence)])),
        throwsA(
          isA<BindingDiagnostic>().having(
            (e) => e.code,
            'code',
            'NAPI_PRESENCE',
          ),
        ),
      );
    }
  });
  test('unimplemented engines fail closed for every declared category', () {
    for (final category in ValueSemantics.values) {
      expect(
        () => validate(
          module([
            function(
              type: DeclaredType(DeclarationId(source, 'Payload'), category),
            ),
          ]),
        ),
        throwsA(isA<BindingDiagnostic>()),
      );
    }
  });
  test('code injection and invalid exported identifiers are diagnosed', () {
    for (final name in ['default', 'x;throw 1', 'x-y', '_private']) {
      expect(
        () => validate(module([function(name: name)])),
        throwsA(isA<BindingDiagnostic>()),
      );
    }
  });
}
