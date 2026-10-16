import 'dart:io';

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
  String parameterName = 'value',
}) => FunctionBinding(
  declaration: DeclarationId(source, name),
  exportName: export ?? name,
  source: SourceLocation(source, 10, 3),
  parameters: [ParameterBinding(parameterName, type, presence: presence)],
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
      expect(emitDart(plan), contains('_readValue(p0, WasmI32.fromInt(0))'));
      expect(emitBoundary(plan), contains('Number.isSafeInteger'));
      expect(emitDeclarations(plan), contains('add(value: number): number'));
    },
  );
  test('all scalar representations share a fixed conversion plan', () {
    final types = <BindingType>[
      const SafeIntType(),
      for (final name in ['bool', 'String', 'double', 'BigInt'])
        DeclaredType(
          DeclarationId(
            Uri.parse('dart:core'),
            name,
            kind: DeclarationKind.classType,
          ),
          ValueSemantics.scalar,
        ),
    ];
    for (final bigint in [false, true]) {
      for (final type in types) {
        final binding = FunctionBinding(
          declaration: DeclarationId(source, 'convert'),
          exportName: 'convert',
          source: SourceLocation(source, 0, 1),
          parameters: [ParameterBinding('value', type)],
          result: type,
          bigint: bigint,
        );
        final plan = lower(validate(module([binding])));
        final input = plan.functions.single.inputs.single;
        final output = plan.functions.single.output;
        expect(input.jsType, output.jsType);
        expect(input.dartType, output.dartType);
        expect(
          emitDeclarations(plan),
          contains('value: ${input.typescriptType}'),
        );
        expect(
          emitDeclarations(plan),
          contains('): ${output.typescriptType};'),
        );
        expect(emitDart(plan), contains('_readValue(p0, WasmI32.fromInt(0))'));
        expect(emitBoundary(plan), contains('"type":"${input.jsType}"'));
      }
    }
  });
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
  test('strict-mode binding names are rejected only as exports', () {
    for (final name in ['eval', 'arguments']) {
      expect(
        () => validate(module([function(name: name)])),
        throwsA(
          isA<BindingDiagnostic>()
              .having((e) => e.code, 'code', 'NAPI_NAME')
              .having((e) => e.source?.offset, 'source offset', 10),
        ),
      );
      expect(
        () => validate(module([function(export: name)])),
        throwsA(
          isA<BindingDiagnostic>().having((e) => e.code, 'code', 'NAPI_NAME'),
        ),
      );
      final plan = lower(
        validate(
          module([
            function(name: name, export: 'safeName', parameterName: name),
          ]),
        ),
      );
      expect(emitDart(plan), contains('target.$name(a0)'));
      expect(emitDart(plan), contains("@pragma('wasm:export', 'safeName')"));
      expect(
        emitDeclarations(plan),
        contains('safeName($name: number): number'),
      );
    }
  });
  test(
    'Node strict-mode imports require aliases for eval and arguments',
    () async {
      final directory = await Directory.systemTemp.createTemp('napi-names-');
      addTearDown(() => directory.delete(recursive: true));
      final consumer = File('${directory.path}/consumer.mjs');
      for (final name in ['eval', 'arguments']) {
        await consumer.writeAsString("import {$name} from './module.wasm';");
        final rejected = await Process.run('node', ['--check', consumer.path]);
        expect(rejected.exitCode, isNot(0));
        expect(rejected.stderr, contains('SyntaxError'));
        await consumer.writeAsString(
          "import {$name as safeName} from './module.wasm';",
        );
        final accepted = await Process.run('node', ['--check', consumer.path]);
        expect(
          accepted.exitCode,
          0,
          reason: '${accepted.stdout}${accepted.stderr}',
        );
      }
    },
  );
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
