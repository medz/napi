import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;
const _source = '''
import 'package:napi/napi.dart';
@NAPI() int add(int left, int right) => left + right;
@NAPI() bool boolean(bool value) => value;
@NAPI() double floating(double value) => value;
@NAPI() String text(String value) => value;
@NAPI() BigInt arbitrary(BigInt value) => value;
@NAPI(bigint: true) int wide(int value) => value;
@NAPI() int? nullable(int? value) => value;
@NAPI() int positional([int value = 42]) => value;
@NAPI() int named(int base, {required int? value, int extra = 42}) => base + (value ?? 0) + extra;
@NAPI() void accept(int value) {}
@NAPI(name: 'Counter')
class DartCounter {
  DartCounter({int initial = 0}) : _value = initial;
  int _value;
  @NAPI(name: 'increment')
  int advance([int amount = 1]) => _value += amount;
  int get value => _value;
  set value(int next) { _value = next; }
  final String label = 'counter';
  static int sum(int a, int b) => a + b;
  static const int initial = 0;
  @NAPI(exclude: true)
  List<int> excluded() => [1];
}
''';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-native-emitter-');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<File> source(String text) async {
    final file = File('${directory.path}/business.dart');
    await file.writeAsString(text);
    return file;
  }

  Future<BindingModule> read(File file) =>
      AnnotationFrontend(packagesPath: _packages, native: true).read(file.uri);

  test(
    'real annotated functions and Counter compile through generated AOT entry',
    () async {
      final input = await source(_source);
      final plan = validateNative(await read(input));
      expect(plan.functions, hasLength(10));
      expect(plan.functions.first.javascriptArity, 2);
      expect(
        plan.functions
            .singleWhere((f) => f.exportName == 'named')
            .javascriptArity,
        0,
      );
      final counter = plan.classes.single;
      expect(counter.binding.exportName, 'Counter');
      expect(
        counter.members
            .where((m) => m.exportName == 'value')
            .map((m) => m.kind),
        [NativeCallKind.getter, NativeCallKind.setter],
      );
      expect(
        counter.members
            .where((m) => m.exportName == 'label')
            .map((m) => m.kind),
        [NativeCallKind.getter],
      );
      expect(counter.members.any((m) => m.exportName == 'excluded'), isFalse);
      final entry = File('${directory.path}/entry.dart');
      await entry.writeAsString(emitNativeDart(plan));
      final compilation = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'aot-snapshot',
        '--packages=$_packages',
        entry.path,
        '--output=${directory.path}/module.aot',
      ]);
      expect(
        compilation.exitCode,
        0,
        reason: '${compilation.stdout}${compilation.stderr}',
      );
      expect(File('${directory.path}/module.aot').existsSync(), isTrue);
      final types = emitNativeDeclarations(plan);
      expect(types, contains('export declare class Counter'));
      expect(
        types,
        contains('constructor(options?: { initial?: number | undefined });'),
      );
      expect(types, contains('increment(amount?: number): number;'));
      expect(types, contains('get value(): number;'));
      expect(types, contains('set value(next: number);'));
      expect(types, contains('static sum(a: number, b: number): number;'));
      expect(types, contains('arbitrary(value: bigint): bigint;'));
      expect(types, contains('wide(value: bigint): bigint;'));
      expect(types, isNot(contains('excluded')));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('external selections lower through the same native plans', () async {
    final input = await source(
      'int increment(int value) => value + 1;\nclass Counter { Counter(); int get value => 42; }',
    );
    final module = await ExternalFrontend(
      const ExternalLibrary([
        ExternalFunction('increment'),
        ExternalClass('Counter'),
      ]),
      packagesPath: _packages,
      native: true,
    ).read(input.uri);
    final plan = validateNative(module);
    expect(plan.functions.single.exportName, 'increment');
    expect(plan.classes.single.members.single.kind, NativeCallKind.getter);
    expect(emitNativeDart(plan), contains('"getter", "value"'));
  });

  test(
    'Dart call paths and parameters keep valid eval and arguments names',
    () async {
      final input = await source('''
import 'package:napi/napi.dart';
@NAPI(name: 'evaluate') int eval(int arguments) => arguments;
@NAPI(name: 'argumentCount') int arguments(int eval) => eval;
''');
      final plan = validateNative(await read(input));
      final dart = emitNativeDart(plan);
      expect(dart, contains('target.eval(a0)'));
      expect(dart, contains('target.arguments(a0)'));
      final types = emitNativeDeclarations(plan);
      expect(types, contains('evaluate(arguments: number): number'));
      expect(types, contains('argumentCount(eval: number): number'));
    },
  );

  for (final (label, declaration, code) in [
    (
      'structural class member',
      '@NAPI() class Bad { List<int> bad(List<int> value) => value; }',
      'NAPI_TYPE',
    ),
    ('generic function', '@NAPI() T bad<T>(T value) => value;', 'NAPI_GENERIC'),
    ('generic class', '@NAPI() class Bad<T> {}', 'NAPI_GENERIC'),
    ('async', '@NAPI() Future<int> bad() async => 1;', 'NAPI_TYPE'),
    (
      'value class',
      '@NAPI(classPolicy: ClassPolicy.value) class Bad {}',
      'NAPI_CLASS',
    ),
    (
      'resource',
      "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') class Bad { void close() {} }",
      'NAPI_CLASS',
    ),
    ('abstract class', '@NAPI() abstract class Bad {}', 'NAPI_CONSTRUCTOR'),
    (
      'static length collision',
      '@NAPI() class Bad { static int length() => 0; }',
      'NAPI_NAME',
    ),
    (
      'static prototype collision',
      "@NAPI() class Bad { @NAPI(name: 'prototype') static int value() => 0; }",
      'NAPI_NAME',
    ),
    (
      'instance constructor collision',
      "@NAPI() class Bad { @NAPI(name: 'constructor') int value() => 0; }",
      'NAPI_NAME',
    ),
    ('external Dart function', '@NAPI() external int bad();', 'NAPI_EXTERNAL'),
  ]) {
    test('native $label fails explicitly before emission', () async {
      final input = await source(
        "import 'package:napi/napi.dart';\n$declaration",
      );
      final module = await read(input);
      expect(
        () => validateNative(module),
        throwsA(
          isA<BindingDiagnostic>()
              .having((e) => e.code, 'code', code)
              .having((e) => e.source!.uri, 'source', input.uri),
        ),
      );
    });
  }
}
