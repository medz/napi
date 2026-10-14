import 'dart:io';

import 'package:napi/napi.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/front_end/fixture_frontend.dart';
import 'package:napi/src/compiler/ir/binding.dart';
import 'package:napi/src/compiler/ir/diagnostic.dart';
import 'package:napi/src/compiler/lowering/lower.dart';
import 'package:napi/src/compiler/lowering/plans.dart';
import 'package:test/test.dart';

void main() {
  late Directory temporary;
  late File fixture;
  setUp(() {
    temporary = Directory.systemTemp.createTempSync('napi-front-end-');
    fixture = File('${temporary.path}/fixture.dart');
  });
  tearDown(() => temporary.deleteSync(recursive: true));

  Future<BindingModule> resolve(
    String source, {
    List<String> names = const ['add'],
  }) {
    fixture.writeAsStringSync(source);
    return FixtureFrontend().resolve(path: fixture.path, functionNames: names);
  }

  test('missing source is a source diagnostic', () async {
    await expectLater(
      FixtureFrontend().resolve(path: fixture.path, functionNames: ['add']),
      throwsA(
        isA<BindingCompilationException>().having(
          (e) => e.diagnostics.single.code,
          'code',
          'source_not_found',
        ),
      ),
    );
  });

  test('one public configurable annotation class', () {
    expect(const NAPI().name, isNull);
    expect(const NAPI(name: 'renamed').name, 'renamed');
  });

  test(
    'resolved immutable declaration contract lowers to separate plans',
    () async {
      final module = await resolve('int add(int a, int b) => a + b;');
      final function = module.functions.single;
      expect(
        function.identity,
        DeclarationIdentity(libraryUri: fixture.uri, name: 'add'),
      );
      expect(function.parameters.map((p) => p.name), ['a', 'b']);
      expect(function.returnType.kind, PrimitiveKind.integer);
      expect(function.returnType.nullable, isFalse);
      expect(function.source.line, 1);
      expect(function.source.column, 1);
      expect(() => module.functions.clear(), throwsUnsupportedError);
      expect(() => function.parameters.clear(), throwsUnsupportedError);
      final plan = lowerModule(module);
      expect(identical(plan.calls.single.binding, function), isTrue);
      expect(
        plan.calls.single.arguments.first.direction,
        ConversionDirection.jsToDart,
      );
      expect(plan.calls.single.result.direction, ConversionDirection.dartToJs);
      expect(plan.calls.single.lifetime.kind, LifetimeKind.synchronousValues);
      expect(plan.calls.single.requiredArgumentCount, 2);
      expect(
        plan.calls.single.arguments.first.operation,
        ConversionOperation.safeIntegerFromJs,
      );
      expect(
        plan.calls.single.result.operation,
        ConversionOperation.safeIntegerToJs,
      );
      expect(() => plan.calls.clear(), throwsUnsupportedError);
      expect(() => plan.calls.single.arguments.clear(), throwsUnsupportedError);
    },
  );

  test(
    'all foundation primitive policies resolve without textual guessing',
    () async {
      final module = await resolve(
        '''
int integer(int x) => x;
double real(double x) => x;
bool truth(bool x) => x;
String text(String x) => x;
void nothing() {}
''',
        names: ['integer', 'real', 'truth', 'text', 'nothing'],
      );
      expect(
        module.functions.map((f) => f.returnType.kind),
        PrimitiveKind.values,
      );
      expect(lowerModule(module).calls.length, 5);
    },
  );

  test(
    'identically spelled user type is not mistaken for dart:core int',
    () async {
      await expectLater(
        resolve('class int {}\nint add(int value) => value;'),
        throwsA(
          isA<BindingCompilationException>().having(
            (e) => e.diagnostics.first.code,
            'code',
            'unsupported_type',
          ),
        ),
      );
    },
  );

  test('diagnostics preserve precise UTF-16 source span', () async {
    try {
      await resolve('// fixture\nString? add() => null;');
      fail('Expected unsupported nullable result');
    } on BindingCompilationException catch (error) {
      final diagnostic = error.diagnostics.single;
      expect(diagnostic.code, 'unsupported_nullable');
      expect(diagnostic.source.uri, fixture.uri);
      expect(diagnostic.source.line, 2);
      expect(diagnostic.source.column, 1);
      expect(diagnostic.source.offset, 11);
      expect(diagnostic.source.length, 7);
    }
  });

  for (final entry in <String, String>{
    'Future<int> add() async => 1;': 'unsupported_function',
    'T add<T>(T value) => value;': 'unsupported_function',
    'int add([int value = 0]) => value;': 'unsupported_parameter',
    'int add({required int value}) => value;': 'unsupported_parameter',
    'int add(value) => 0;': 'unsupported_parameter',
    'add() => 0;': 'explicit_type_required',
    'List<int> add() => [];': 'unsupported_type',
    'int add(int? value) => value ?? 0;': 'unsupported_nullable',
    'int get add => 0;': 'unsupported_function',
    'external int add();': 'unsupported_function',
  }.entries) {
    test('rejects ${entry.key}', () async {
      await expectLater(
        resolve(entry.key),
        throwsA(
          isA<BindingCompilationException>().having(
            (e) => e.diagnostics.map((d) => d.code),
            'diagnostic codes',
            contains(entry.value),
          ),
        ),
      );
    });
  }

  test('missing selection and source errors are explicit', () async {
    await expectLater(
      resolve('int other() => 1;'),
      throwsA(
        isA<BindingCompilationException>().having(
          (e) => e.diagnostics.single.code,
          'code',
          'missing_function',
        ),
      ),
    );
    await expectLater(
      resolve('int add() => unknown;'),
      throwsA(
        isA<BindingCompilationException>().having(
          (e) => e.diagnostics.map((d) => d.code),
          'codes',
          contains('dart_analysis_error'),
        ),
      ),
    );
    await expectLater(
      resolve('int add() => 1;', names: []),
      throwsA(
        isA<BindingCompilationException>().having(
          (e) => e.diagnostics.single.code,
          'code',
          'empty_selection',
        ),
      ),
    );
  });

  test(
    'callable then export cannot corrupt dynamic import resolution',
    () async {
      final module = await resolve('int then() => 1;', names: ['then']);
      expect(
        () => lowerModule(module),
        throwsA(
          isA<BindingCompilationException>().having(
            (e) => e.diagnostics.single.code,
            'code',
            'reserved_module_export',
          ),
        ),
      );
    },
  );

  test('analysis rejects duplicate exports and private declarations', () async {
    final duplicate = await resolve('int add() => 1;', names: ['add', 'add']);
    expect(
      () => lowerModule(duplicate),
      throwsA(
        isA<BindingCompilationException>().having(
          (e) => e.diagnostics.single.code,
          'code',
          'duplicate_public_name',
        ),
      ),
    );
    final private = await resolve('int _add() => 1;', names: ['_add']);
    expect(
      () => validateModule(private),
      throwsA(
        isA<BindingCompilationException>().having(
          (e) => e.diagnostics.single.code,
          'code',
          'private_declaration',
        ),
      ),
    );
  });

  test(
    'analysis rejects unsupported policies even for hand-constructed IR',
    () async {
      final original = (await resolve('int add() => 1;')).functions.single;
      final bad = FunctionBinding(
        identity: original.identity,
        source: original.source,
        dartName: 'add',
        publicName: 'default',
        parameters: [
          ParameterBinding(
            name: 'value',
            type: const PrimitiveTypePolicy(PrimitiveKind.voidType),
            source: original.source,
          ),
        ],
        returnType: const PrimitiveTypePolicy(
          PrimitiveKind.integer,
          nullable: true,
        ),
      );
      expect(
        () => lowerModule(
          BindingModule(sourceUri: fixture.uri, functions: [bad]),
        ),
        throwsA(
          isA<BindingCompilationException>().having(
            (e) => e.diagnostics.map((d) => d.code),
            'codes',
            containsAll([
              'invalid_public_name',
              'unsupported_void_parameter',
              'unsupported_nullable',
            ]),
          ),
        ),
      );
    },
  );
}
