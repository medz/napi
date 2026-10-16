import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

final _source = Uri.file('/fixture/arguments.dart');
BindingModule _module(List<ParameterBinding> parameters) => BindingModule(
  source: _source,
  functions: [
    FunctionBinding(
      declaration: DeclarationId(_source, 'run'),
      exportName: 'run',
      source: SourceLocation(_source, 0, 1),
      parameters: parameters,
      result: const SafeIntType(),
    ),
  ],
);

void main() {
  test(
    'unsupported or inconsistent defaults fail before build output',
    () async {
      final root = await Directory.systemTemp.createTemp('napi-default-');
      addTearDown(() => root.delete(recursive: true));
      for (final parameter in [
        const ParameterBinding(
          'value',
          SafeIntType(),
          kind: ParameterKind.optionalPositional,
        ),
        const ParameterBinding(
          'value',
          SafeIntType(),
          kind: ParameterKind.optionalNamed,
          defaultSource: '_privateConstant',
        ),
        const ParameterBinding(
          'value',
          SafeIntType(),
          kind: ParameterKind.optionalNamed,
          defaultValue: ScalarDefault('wrong type'),
        ),
        const ParameterBinding(
          'value',
          SafeIntType(),
          defaultValue: ScalarDefault(7),
        ),
      ]) {
        await expectLater(
          buildModule(
            bindings: _module([parameter]),
            output: Directory('${root.path}/not-created/output'),
            sdk: DartSdkAdapter(executable: 'must-not-run'),
          ),
          throwsA(
            isA<BindingDiagnostic>().having(
              (e) => e.code,
              'code',
              'NAPI_DEFAULT',
            ),
          ),
        );
        expect(await root.list().length, 0);
      }
    },
  );

  test('Dart parameter ordering is checked before lowering', () {
    const required = ParameterBinding('first', SafeIntType());
    const optional = ParameterBinding(
      'second',
      SafeIntType(),
      kind: ParameterKind.optionalPositional,
      defaultValue: ScalarDefault(1),
    );
    const named = ParameterBinding(
      'third',
      SafeIntType(),
      kind: ParameterKind.requiredNamed,
    );
    for (final parameters in [
      [optional, required],
      [named, required],
      [optional, named],
      [named, optional],
    ]) {
      expect(
        () => validate(_module(parameters)),
        throwsA(
          isA<BindingDiagnostic>().having(
            (e) => e.code,
            'code',
            'NAPI_PARAMETER',
          ),
        ),
      );
    }
  });

  test('source defaults are evaluated in their declaring library', () async {
    final root = await Directory.systemTemp.createTemp('napi-default-source-');
    addTearDown(() => root.delete(recursive: true));
    await File('${root.path}/origin.dart').writeAsString('''
import 'package:napi/napi.dart';
const _private = 6 * 7;
@NAPI() int run([int value = _private]) => value;
''');
    final entry = File('${root.path}/entry.dart');
    await entry.writeAsString("export 'origin.dart' show run;");
    final module = await AnnotationFrontend(
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
    ).read(entry.uri);
    final parameter = module.functions.single.parameters.single;
    expect(parameter.defaultSource, '_private');
    expect(parameter.defaultValue?.value, 42);
    final plan = lower(validate(module));
    expect(
      plan.functions.single.representation,
      ExportRepresentation.callableGlobal,
    );
    expect(emitDart(plan), contains('a0 = 42;'));
    expect(emitDart(plan), isNot(contains('_private')));
  });

  test(
    'many named defaults produce one linear call rather than combinations',
    () {
      final plan = lower(
        validate(
          _module([
            for (var i = 0; i < 40; i++)
              ParameterBinding(
                'value$i',
                const SafeIntType(),
                kind: ParameterKind.optionalNamed,
                defaultValue: ScalarDefault(i),
              ),
          ]),
        ),
      );
      final dart = emitDart(plan);
      expect('value = target.run('.allMatches(dart), hasLength(1));
      expect(dart.length, lessThan(15000));
      expect(dart, contains('value39: a39'));
    },
  );
}
