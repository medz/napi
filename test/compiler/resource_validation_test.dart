import 'dart:io';

import 'package:napi/src/compiler/analysis/result.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:test/test.dart';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-resources-');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<ValidatedModule> read(String source) async {
    final input = File('${directory.path}/business.dart');
    await input.writeAsString("import 'package:napi/napi.dart';\n$source");
    return validate(
      await AnnotationFrontend(packagesPath: packages).read(input.uri),
    );
  }

  test(
    'cleanup completion is separate from its original Dart signature',
    () async {
      final module = await read('''
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  Resource();
  @NAPI(name: 'release') void close([int reason = 7]) {}
  int read() => 1;
}
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'finish')
class AsyncResource {
  AsyncResource();
  Future<void> finish({required int? reason}) => Future.value();
}
@NAPI() Resource identity(Resource value) => value;
''');
      final sync = module.classes.first.cleanup!;
      expect(sync.isCleanup, isTrue);
      expect(sync.returnsFuture, isTrue);
      expect(sync.result, isNull);
      expect(sync.exportName, 'release');
      expect((sync.parameters.single.defaultValue as ScalarDefault).value, 7);
      final async = module.classes.last.cleanup!;
      expect(async.returnsFuture, isTrue);
      expect(isFutureType(async.result), isTrue);
      expect(resultPayload(async.result), isNull);
      expect(async.parameters.single.kind, ParameterKind.requiredNamed);
      expect(
        isReferenceType(
          module.bindings.functions.single.result,
          module.bindings.classes,
        ),
        isTrue,
      );
    },
  );

  for (final (label, cleanup, code) in [
    (
      'excluded cleanup',
      '@NAPI(exclude: true) void close() {}',
      'NAPI_RESOURCE',
    ),
    ('nonvoid cleanup', 'int close() => 1;', 'NAPI_RESOURCE'),
    (
      'nonvoid Future cleanup',
      'Future<int> close() async => 1;',
      'NAPI_RESOURCE',
    ),
    ('async void cleanup', 'void close() async {}', 'NAPI_TYPE'),
    ('nullable Future cleanup', 'Future<void>? close() => null;', 'NAPI_TYPE'),
    ('FutureOr cleanup', 'FutureOr<void> close() {}', 'NAPI_TYPE'),
  ]) {
    test('$label is diagnosed without changing declaration metadata', () async {
      await expectLater(
        read('''
import 'dart:async';
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource { $cleanup }
'''),
        throwsA(isA<BindingDiagnostic>().having((e) => e.code, 'code', code)),
      );
    });
  }

  test(
    'reference and resource shapes retain one stable class ID order',
    () async {
      final module = await read('''
@NAPI() class First { First(); }
@NAPI(classPolicy: ClassPolicy.value) class Data { final int value = 1; }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource { Resource(); void close() {} }
@NAPI() class Last { Last(); }
@NAPI() List<Resource?> keep(List<Resource?> value) => value;
''');
      expect(module.classes.map((c) => c.binding.exportName), [
        'First',
        'Resource',
        'Last',
      ]);
      expect(module.classes.map((c) => c.classId), [0, 1, 2]);
      expect(resourcePolicies(module.classes), {1: 1});
    },
  );

  test(
    'equivalent cleanup views share a policy across sync and async results',
    () async {
      final module = await read('''
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class First { First._(); void close({int code = 1}); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class Second { Second._(); Future<void> close({int code = 1}); }
''');
      expect(resourcePolicies(module.classes), {0: 0, 1: 0});
    },
  );

  test(
    'cleanup target and defaults distinguish unrelated resource policies',
    () async {
      final module = await read('''
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class First { First._(); void close({int code = 1}); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class Second { Second._(); void close({int code = 2}); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'finish')
abstract class Third { Third._(); void finish({int code = 1}); }
''');
      expect(resourcePolicies(module.classes), {0: 0, 1: 1, 2: 2});
    },
  );

  test(
    'cleanup payload policies ignore class binder identity and slots',
    () async {
      final module = await read('''
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class First<T> { First._(); void close(T value); T echo(T value); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class Second<U> { Second._(); void close(U value); U echo(U value); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class Extra<Unused, V> { Extra._(); void close(V value); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class Pair<A, B> { Pair._(); void close(A first, B second); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class Reordered<X, Unused, Z> { Reordered._(); void close(Z first, X second); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class Repeated<V> { Repeated._(); void close(V first, V second); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class Nullable<T> { Nullable._(); void close(T? value); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class Optional<T> { Optional._(); void close([T? value]); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class Named<T> { Named._(); void close({required T value}); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class Structural<T> { Structural._(); void close(List<T> value); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class Scalar { Scalar._(); void close(int value); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class DefaultOne<T> { DefaultOne._(); void close(T value, {int code = 1}); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class DefaultTwo<U> { DefaultTwo._(); void close(U value, {int code = 2}); }
''');
      final policies = resourcePolicies(module.classes);
      int policy(String name) =>
          policies[module.classes
              .singleWhere((shape) => shape.binding.exportName == name)
              .classId]!;
      expect(policy('First'), policy('Second'));
      expect(policy('First'), policy('Extra'));
      expect(policy('Pair'), policy('Reordered'));
      expect(policy('Pair'), policy('Repeated'));
      expect({
        for (final name in [
          'First',
          'Pair',
          'Nullable',
          'Optional',
          'Named',
          'Structural',
          'Scalar',
          'DefaultOne',
          'DefaultTwo',
        ])
          policy(name),
      }, hasLength(9));
      final ordinary = module.classes
          .take(2)
          .map(
            (shape) => shape.members.singleWhere(
              (member) => member.exportName == 'echo',
            ),
          )
          .toList();
      expect(
        referenceMemberAccepts(ordinary[0], ordinary[1], module.classes),
        isFalse,
      );
    },
  );

  test(
    'cleanup can become asynchronous through a selected derived resource',
    () async {
      final module = await read('''
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Parent { void close() {} }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Child extends Parent { Child(); @override Future<void> close() async {} }
''');
      expect(resourcePolicies(module.classes), {0: 0, 1: 0});
      expect(module.classes.last.memberships, {0, 1});
    },
  );

  test(
    'ordinary selected methods cannot silently acquire cleanup semantics',
    () async {
      await expectLater(
        read('''
@NAPI() class Parent { void close() {} }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Child extends Parent { @override void close() {} }
'''),
        throwsA(
          isA<BindingDiagnostic>().having(
            (e) => e.code,
            'code',
            'NAPI_INHERITANCE',
          ),
        ),
      );
    },
  );

  test(
    'known composite cleanup conflicts are rejected before code generation',
    () async {
      await expectLater(
        read('''
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
abstract class First { First._(); void close(); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'finish')
abstract class Second { Second._(); void finish(); }
@NAPI() class Both implements First, Second {
  Both();
  @override void close() {}
  @override void finish() {}
}
'''),
        throwsA(isA<BindingDiagnostic>()),
      );
    },
  );

  for (final signature in [
    'void close() async {}',
    'Future<void>? close() => null;',
  ]) {
    test(
      'unselected cleanup overrides retain the supported completion shape',
      () async {
        await expectLater(
          read('''
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Parent { void close() {} }
class Middle extends Parent { @override $signature }
@NAPI() class Child extends Middle {}
'''),
          throwsA(
            isA<BindingDiagnostic>().having(
              (e) => e.code,
              'code',
              'NAPI_INHERITANCE',
            ),
          ),
        );
      },
    );
  }
}
