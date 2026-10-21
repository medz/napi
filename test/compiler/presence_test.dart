import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/ir/defaults.dart';
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
    expect((parameter.defaultValue as ScalarDefault?)?.value, 42);
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
      String generate(int count) => emitDart(
        lower(
          validate(
            _module([
              for (var i = 0; i < count; i++)
                ParameterBinding(
                  'value$i',
                  const SafeIntType(),
                  kind: ParameterKind.optionalNamed,
                  defaultValue: ScalarDefault(i),
                ),
            ]),
          ),
        ),
      );
      final dart = generate(40);
      final fixedSize = generate(0).length;
      final halfGrowth = generate(20).length - fixedSize;
      final fullGrowth = dart.length - fixedSize;
      expect('value = target.run('.allMatches(dart), hasLength(1));
      // Runtime bootstrap is fixed overhead, independent of parameter count.
      expect(fullGrowth, lessThan(15000));
      expect(fullGrowth, lessThan(halfGrowth * 2.2));
      expect(dart, contains('value39: a39'));
    },
  );

  test(
    'built-in graph defaults retain actual const types in both frontends',
    () async {
      final root = await Directory.systemTemp.createTemp('napi-const-default-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/entry.dart');
      await file.writeAsString('''import 'package:napi/napi.dart';
const _items = <Dictionary<int>>[Dictionary<int>(<String, Never>{})];
@NAPI() bool run([
  List<int> a = const <Never>[],
  List<Dictionary<int>> b = _items,
  List<int?> c = const <Null>[null],
  (List<int>, {double zero}) d = (const <Never>[], zero: -0.0),
]) => true;
''');
      for (final external in [false, true]) {
        final module = await readLibraryBindings(
          library: file.uri,
          packagesPath: File('.dart_tool/package_config.json').absolute.path,
          external: external
              ? const ExternalLibrary([ExternalFunction('run')])
              : null,
        );
        final parameters = module.functions.single.parameters;
        expect(
          constantDefaultSource(parameters[0].defaultValue!),
          'const <Never>[]',
        );
        expect(
          constantDefaultSource(parameters[1].defaultValue!),
          'const <Map<String, int>>[const <String, Never>{}]',
        );
        final dart = emitDart(lower(validate(module)));
        expect(dart, contains('(const <Never>[] as List<int>)'));
        expect(dart, contains('as List<napi.Dictionary<int>>'));
        expect(dart, contains('const <Null>[null]'));
        expect(dart, contains('zero: -0.0'));
      }
    },
  );

  test(
    'opaque container defaults retain their evaluated Never element type',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'napi-opaque-default-',
      );
      addTearDown(() => root.delete(recursive: true));
      final file = await File('${root.path}/entry.dart').writeAsString('''
import 'package:napi/napi.dart';
@NAPI() bool run<T>([List<T> value = const <Never>[]]) => true;
''');
      final module = await AnnotationFrontend(
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
      ).read(file.uri);
      final plan = lower(validate(module));
      final input = plan.functions.single.inputs.single as ListConversion;
      expect(input.element, isA<OpaqueConversion>());
      expect(
        constantDefaultSource(
          module.functions.single.parameters.single.defaultValue!,
        ),
        'const <Never>[]',
      );
      expect(
        emitDart(plan),
        contains('const <Never>[] as List<_NapiHostValue>'),
      );
    },
  );

  test('opaque defaults require compatible payloads even with assignability metadata', () {
    final parameter = DeclarationId(
      _source,
      'T',
      kind: DeclarationKind.typeParameter,
    );
    final list = DeclarationId(
      Uri.parse('dart:core'),
      'List',
      kind: DeclarationKind.classType,
    );
    expect(
      () => validateParameterDefault(
        ParameterBinding(
          'value',
          DeclaredType(
            list,
            ValueSemantics.structural,
            typeArguments: [TypeParameterType(parameter)],
          ),
          kind: ParameterKind.optionalPositional,
          defaultValue: ListDefault(
            DeclaredType(
              list,
              ValueSemantics.structural,
              typeArguments: [
                DeclaredType(
                  DeclarationId(
                    Uri.parse('dart:core'),
                    'String',
                    kind: DeclarationKind.classType,
                  ),
                  ValueSemantics.scalar,
                ),
              ],
            ),
            [const ScalarDefault('not a host value')],
          ),
          defaultTypeIsAssignable: true,
        ),
        SourceLocation(_source, 0, 1),
        opaqueParameters: {parameter},
      ),
      throwsA(
        isA<BindingDiagnostic>().having((e) => e.code, 'code', 'NAPI_DEFAULT'),
      ),
    );
  });

  test(
    'const graphs cannot bypass unsupported declared default leaves',
    () async {
      final root = await Directory.systemTemp.createTemp('napi-const-default-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/entry.dart');
      for (final declaration in [
        '@NAPI() class Item { const Item._(); } '
            '@NAPI() bool run([List<Item> value = const [Item._()]]) => true;',
      ]) {
        await file.writeAsString(
          "import 'package:napi/napi.dart';\n$declaration",
        );
        final module = await AnnotationFrontend(
          packagesPath: File('.dart_tool/package_config.json').absolute.path,
        ).read(file.uri);
        expect(
          () => validate(module),
          throwsA(
            isA<BindingDiagnostic>().having(
              (e) => e.code,
              'code',
              'NAPI_DEFAULT',
            ),
          ),
        );
      }
    },
  );

  test('shared constant graphs have bounded expansion before generation', () async {
    final root = await Directory.systemTemp.createTemp('napi-const-budget-');
    addTearDown(() => root.delete(recursive: true));
    final file = File('${root.path}/entry.dart');
    await file.writeAsString(
      [
        "import 'package:napi/napi.dart';",
        'const a0 = <int>[0];',
        for (var i = 1; i <= 14; i++) 'const a$i = [a${i - 1}, a${i - 1}];',
        '@NAPI() bool run([${'List<' * 15}int${'>' * 15} value = a14]) => true;',
      ].join('\n'),
    );
    final limit = throwsA(
      isA<BindingDiagnostic>()
          .having((e) => e.code, 'code', 'NAPI_DEFAULT')
          .having((e) => e.message, 'message', contains('10000')),
    );
    await expectLater(
      AnnotationFrontend(
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
      ).read(file.uri),
      limit,
    );
    BindingType type = const SafeIntType();
    ConstantDefault value = const ScalarDefault(0);
    for (var i = 0; i < 15; i++) {
      type = DeclaredType(
        DeclarationId(
          Uri.parse('dart:core'),
          'List',
          kind: DeclarationKind.classType,
        ),
        ValueSemantics.structural,
        typeArguments: [type],
      );
      value = ListDefault(type, [value, value]);
    }
    expect(
      () => validateParameterDefault(
        ParameterBinding(
          'value',
          type,
          kind: ParameterKind.optionalPositional,
          defaultValue: value,
        ),
        SourceLocation(file.uri, 0, 1),
      ),
      limit,
    );
  });

  test(
    'constant depth counts containers without rejecting the final scalar',
    () {
      BindingType type = const SafeIntType();
      ConstantDefault value = const ScalarDefault(0);
      for (var i = 1; i <= 65; i++) {
        type = DeclaredType(
          DeclarationId(
            Uri.parse('dart:core'),
            'List',
            kind: DeclarationKind.classType,
          ),
          ValueSemantics.structural,
          typeArguments: [type],
        );
        value = ListDefault(type, [value]);
        if (i < 64) continue;
        expect(
          () => validateParameterDefault(
            ParameterBinding(
              'value',
              type,
              kind: ParameterKind.optionalPositional,
              defaultValue: value,
            ),
            SourceLocation(_source, 0, 1),
          ),
          i == 64
              ? returnsNormally
              : throwsA(
                  isA<BindingDiagnostic>().having(
                    (e) => e.code,
                    'code',
                    'NAPI_DEFAULT',
                  ),
                ),
        );
      }
    },
  );
}
