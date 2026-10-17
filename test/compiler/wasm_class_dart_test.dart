import 'dart:io';

import 'package:napi/napi.dart' show NAPI;
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;
const _source = '''
import 'package:napi/napi.dart';
@NAPI() int add(int left, int right) => left + right;
@NAPI() int choose([int value = 7]) => value;
@NAPI(name: 'Counter')
class DartCounter {
  DartCounter([this.value = 0]);
  int value;
  final String label = 'counter';
  String? _tag;
  String? get tag => _tag;
  set tag(String? next) { _tag = next; }
  @NAPI(name: 'increment') int advance([int amount = 1]) => value += amount;
  int named({int amount = 2}) => value += amount;
  void reset(int next) { value = next; }
  void get empty {}
  bool boolean(bool value) => value;
  double floating(double value) => value;
  String text(String value) => value;
  BigInt arbitrary(BigInt value) => value;
  static int sum(int left, int right) => left + right;
  static const int initial = 0;
  @NAPI(exclude: true) List<int> excluded() => [1];
}
void main() => throw StateError('Business main must not run');
''';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-wasm-class-dart-');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<File> source(String text) async {
    final file = File('${directory.path}/business.dart');
    await file.writeAsString(text);
    return file;
  }

  Future<BindingModule> read(File file) =>
      AnnotationFrontend(packagesPath: _packages).read(file.uri);

  test('class calls share complete ordered conversion contexts', () async {
    final module = await read(await source(_source));
    final plan = lower(validate(module));
    expect(plan.classes.single.binding.exportName, 'Counter');
    expect(
      plan.functions.first.representation,
      ExportRepresentation.nativeFunction,
    );
    expect(plan.functions.first.coreExportName, 'add');
    expect(
      plan.functions.last.representation,
      ExportRepresentation.callableGlobal,
    );
    expect(plan.functions.last.coreExportName, 'napi:call:1');
    final counter = plan.classes.single;
    expect(counter.constructor!.coreExportName, 'napi:class:0:new');
    expect(counter.constructor!.output, isNull);
    expect(counter.constructor!.outputContext, isNull);
    final contexts = [
      for (final call in plan.calls) ...[
        ...call.inputContexts,
        ?call.outputContext,
      ],
    ];
    expect(contexts, List.generate(plan.conversions.length, (i) => i));
    for (final call in plan.calls) {
      expect(call.parameters.length, call.inputs.length);
      expect(call.inputContexts.length, call.inputs.length);
      expect(call.outputContext == null, call.output == null);
      for (final (index, input) in call.inputs.indexed) {
        expect(
          identical(plan.conversions[call.inputContexts[index]], input),
          isTrue,
        );
      }
    }
    final value = counter.members
        .where((m) => m.exportName == 'value')
        .toList();
    expect(value.map((m) => m.kind), [
      MemberCallKind.getter,
      MemberCallKind.setter,
    ]);
    expect(identical(value.first.binding, value.last.binding), isTrue);
    expect(value.last.binding.kind, MemberKind.field);
    expect(value.last.outputContext, isNull);
    expect(
      counter.members.where((m) => m.exportName == 'label').single.kind,
      MemberCallKind.getter,
    );
    expect(
      counter.members.singleWhere((m) => m.exportName == 'reset').outputContext,
      isNull,
    );
    expect(
      counter.members.singleWhere((m) => m.exportName == 'empty').outputContext,
      isNull,
    );
    expect(
      counter.members.singleWhere((m) => m.exportName == 'sum').isStatic,
      isTrue,
    );
    expect(counter.members.any((m) => m.exportName == 'excluded'), isFalse);
    expect(() => plan.calls.clear(), throwsUnsupportedError);
    expect(() => plan.conversions.clear(), throwsUnsupportedError);
    final native = validateNative(module);
    expect(
      native.classes.single.members.map((m) => m.exportName),
      counter.members.map((m) => m.exportName),
    );
  });

  test('real generated class entrypoint compiles to Dart Wasm', () async {
    final plan = lower(validate(await read(await source(_source))));
    final entry = File('${directory.path}/entry.dart');
    final code = emitDart(plan);
    expect(code, contains('WasmAnyRef.fromObject(value).externalize()'));
    expect(
      code,
      contains('reference.internalize().toObject() as target.DartCounter'),
    );
    expect(code, contains('target.DartCounter.sum(a0, a1)'));
    expect(code, contains('object.advance(a0)'));
    expect(code, contains('object.value = a0'));
    expect(code, contains("@pragma('wasm:export', 'add')"));
    await entry.writeAsString(code);
    final compiled = await DartSdkAdapter().compile(
      sourcePath: entry.path,
      outputPath: '${directory.path}/module.wasm',
      packagesPath: _packages,
    );
    expect(File(compiled.wasmPath).lengthSync(), greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'annotation and external class selections emit the same Dart calls',
    () async {
      final input = await source('''
import 'package:napi/napi.dart';
@NAPI(name: 'PublicCounter') class Counter {
  Counter([this.value = 3]);
  int value;
  @NAPI(name: 'increment') int advance([int by = 2]) => value += by;
}
''');
      final annotated = lower(validate(await read(input)));
      final external = lower(
        validate(
          await ExternalFrontend(
            const ExternalLibrary([
              ExternalClass(
                'Counter',
                config: NAPI(name: 'PublicCounter'),
                members: [
                  ExternalMember.method(
                    'advance',
                    config: NAPI(name: 'increment'),
                  ),
                ],
              ),
            ]),
            packagesPath: _packages,
          ).read(input.uri),
        ),
      );
      expect(emitDart(external), emitDart(annotated));
    },
  );

  for (final (label, declaration, code) in [
    (
      'semantic generic class',
      '@NAPI() class Bad<T extends num> {}',
      'NAPI_TYPE',
    ),
    (
      'generic member',
      '@NAPI() class Bad { T identity<T>(T value) => value; }',
      'NAPI_GENERIC',
    ),
    (
      'async void member',
      '@NAPI() class Bad { void read() async {} }',
      'NAPI_TYPE',
    ),
    (
      'value constructor missing a mapped field',
      "@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new') class Bad { Bad(int absent); }",
      'NAPI_VALUE',
    ),
    (
      'non-void resource cleanup',
      "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') class Bad { int close() => 0; }",
      'NAPI_RESOURCE',
    ),
  ]) {
    test('unsupported $label reports source before lowering', () async {
      final input = await source(
        "import 'package:napi/napi.dart';\n$declaration",
      );
      final module = await read(input);
      expect(
        () => validate(module),
        throwsA(
          isA<BindingDiagnostic>()
              .having((e) => e.code, 'code', code)
              .having((e) => e.source!.uri, 'source', input.uri),
        ),
      );
    });
  }
}
