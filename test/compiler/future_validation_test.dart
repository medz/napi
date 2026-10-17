import 'dart:io';

import 'package:napi/src/compiler/analysis/result.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  final packages = File('.dart_tool/package_config.json').absolute.path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'napi-future-validation-',
    );
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<ValidatedModule> read(String source) async {
    final file = File('${directory.path}/business.dart');
    await file.writeAsString("import 'package:napi/napi.dart';\n$source");
    return validate(
      await AnnotationFrontend(packagesPath: packages).read(file.uri),
    );
  }

  test(
    'canonical Future aliases and synchronous producers share completion',
    () async {
      final module = await read('''
typedef Later<T> = Future<T>;
@NAPI() Later<int> immediate() => Future.value(1);
@NAPI() Future<int?> nullable() async => null;
@NAPI() Future<void> empty() async {}
@NAPI() class Counter {
  Counter();
  Future<int> get value => Future.value(3);
  Future<void> clear() async {}
  static Later<String> text() => Future.value('value');
}
''');
      final functions = module.bindings.functions;
      expect(
        functions.map((f) => isFutureType(f.result)),
        everyElement(isTrue),
      );
      expect(functions.first.isAsync, isFalse);
      expect(functions.first.result.alias, isNotNull);
      expect(resultPayload(functions.first.result), isA<SafeIntType>());
      expect(
        resultPayload(functions[1].result)!.nullability,
        TypeNullability.nullable,
      );
      expect(resultPayload(functions[2].result), isNull);
      expect(
        module.classes.single.members.map((m) => isFutureType(m.result)),
        everyElement(isTrue),
      );
    },
  );

  test('a user class named Future remains a selected reference type', () async {
    final module = await read('''
@NAPI() class Future { Future(); }
@NAPI() Future identity(Future value) => value;
''');
    final type = module.bindings.functions.single.result;
    expect(isFutureType(type), isFalse);
    expect(identical(resultPayload(type), type), isTrue);
  });

  test(
    'matching Future<void> inheritance retains its completion contract',
    () async {
      final module = await read('''
@NAPI() class Parent { Future<void> run() async {} }
@NAPI() class Child extends Parent {
  Child();
  @override Future<void> run() async {}
}
''');
      final child = module.classes.last;
      expect(child.memberships, {0, 1});
      expect(child.prototypeProperties.single.method!.classId, 1);
    },
  );

  for (final (name, source) in [
    ('nullable Future object', '@NAPI() Future<int>? value() => null;'),
    ('FutureOr', '@NAPI() FutureOr<int> value() => 1;'),
    ('Future input', '@NAPI() int value(Future<int> input) => 1;'),
    ('nested Future', '@NAPI() Future<Future<int>> value() => throw 1;'),
    ('async void function', '@NAPI() void value() async {}'),
    ('async void member', '@NAPI() class Box { void value() async {} }'),
    ('sync generator', '@NAPI() Iterable<int> value() sync* { yield 1; }'),
  ]) {
    test(
      '$name is diagnosed before either backend can drop metadata',
      () async {
        await expectLater(
          read("import 'dart:async';\n$source"),
          throwsA(
            isA<BindingDiagnostic>().having((e) => e.code, 'code', 'NAPI_TYPE'),
          ),
        );
      },
    );
  }

  for (final source in [
    '''
@NAPI() class Parent { void run() {} }
@NAPI() class Child extends Parent {
  @override Future<void> run() async {}
}
''',
    '''
@NAPI() class Parent { void run() {} }
class Middle extends Parent { @override Future<void> run() async {} }
@NAPI() class Child extends Middle {}
''',
    '''
@NAPI() class Parent { void run() {} }
class Middle extends Parent { @override void run() async {} }
@NAPI() class Child extends Middle {}
''',
  ]) {
    test(
      'a synchronous void ancestor cannot silently become asynchronous',
      () async {
        await expectLater(
          read(source),
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
