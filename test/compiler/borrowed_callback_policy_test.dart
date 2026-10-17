import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-borrowed-policy-');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<BindingModule> read(String text) async {
    final file = File('${directory.path}/entry.dart');
    await file.writeAsString("import 'package:napi/napi.dart';\n$text");
    return AnnotationFrontend(packagesPath: _packages).read(file.uri);
  }

  test('direct callbacks use typed children and callable bindings', () async {
    final module = await read('''
typedef Transform = List<(int, String?)>? Function((bool, List<int?>) source);
@NAPI() int run(Transform callback) => callback((true, [1]))?.length ?? 0;
@NAPI(bigint: true) int big(int Function(int, List<int>) callback) => callback(1, [2]);
@NAPI() int notify(void Function() callback) { callback(); return 1; }
''');
    final wasm = lower(validate(module));
    final native = validateNative(module);
    for (final inputs in [
      wasm.functions.map((f) => f.inputs.single).toList(),
      native.functions.map((f) => f.inputs.single).toList(),
    ]) {
      final transform = inputs[0] as CallbackConversion;
      expect(transform.inputs.single, isA<RecordConversion>());
      expect(transform.output, isA<ListConversion>());
      expect(
        transform.dartType,
        'List<(int, String?)>? Function((bool, List<int?>))',
      );
      expect(transform.jsType, 'function');
      expect(
        transform.inputs.single.context,
        'run.callback callback argument 1',
      );
      expect(transform.output!.context, 'run.callback callback result');
      expect(
        conversionGraph([transform]).whereType<ScalarConversion>(),
        hasLength(4),
      );
      final big = inputs[1] as CallbackConversion;
      expect(big.inputs.first.typescriptType, 'bigint');
      expect(big.inputs.last.typescriptType, 'Array<bigint>');
      expect(big.output!.typescriptType, 'bigint');
      final notify = inputs[2] as CallbackConversion;
      expect(notify.output, isNull);
      expect(notify.dartType, 'void Function()');
      expect(notify.typescriptType, '() => void');
    }
    expect(
      wasm.functions.every(
        (f) => f.representation == ExportRepresentation.callableGlobal,
      ),
      isTrue,
    );
  });

  test(
    'outer calls retain presence, defaults and selected class behavior',
    () async {
      final module = await read('''
@NAPI() int optional([int Function(int)? callback]) => callback?.call(1) ?? 0;
@NAPI() int named({required int Function(int) callback, int Function(int)? fallback = null}) => callback(1);
@NAPI() class Calls {
  Calls(void Function() initialize) { initialize(); }
  Calls.named(void Function() initialize) { initialize(); }
  void Function()? _saved;
  set saved(void Function() callback) { _saved = callback; }
  int run(int Function(int value) callback) => callback(1);
}
@NAPI() class Child extends Calls {
  Child(void Function() initialize) : super(initialize);
  @override int run(int Function(int renamed) callback) => callback(2);
}
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') class Resource {
  Resource();
  int run(int Function(int) callback) => callback(1);
  void close() {}
}
''');
      final wasm = lower(validate(module));
      final native = validateNative(module);
      final optional = wasm.functions.first;
      expect(optional.parameters.single.presence, ParameterPresence.optional);
      expect(optional.inputs.single.dartType, 'int Function(int)?');
      expect(
        optional.inputs.single.typescriptType,
        '((arg0: number) => number) | null',
      );
      expect(
        native.classes.first.members.any(
          (m) =>
              m.kind == NativeCallKind.setter &&
              m.inputs.single is CallbackConversion,
        ),
        isTrue,
      );
      for (final code in [
        emitDeclarations(wasm),
        emitNativeDeclarations(native),
      ]) {
        expect(code, contains('callback?: ((arg0: number) => number) | null'));
        expect(
          code,
          contains(
            'options: { callback: (arg0: number) => number; fallback?: ((arg0: number) => number) | null | undefined }',
          ),
        );
        expect(code, contains('constructor(initialize: () => void);'));
        expect(code, contains('set saved(callback: () => void);'));
        expect(code, contains('static named(initialize: () => void): Calls;'));
      }
    },
  );

  test('actual TypeScript consumers enforce callback payload contracts', () async {
    final module = await read('''
@NAPI() int run(int Function(int, String) callback) => callback(1, 'x');
@NAPI() int optional([int Function(int)? callback]) => callback?.call(1) ?? 0;
@NAPI(bigint: true) int big(int Function(int) callback) => callback(1);
@NAPI() int record(List<int> Function((int, {String text})) callback) => callback((1, text: 'x')).length;
@NAPI() class Calls {
  Calls(void Function() initialize) { initialize(); }
  int run(int Function(int) callback) => callback(1);
}
''');
    final declarations = {
      'wasm': emitDeclarations(lower(validate(module))),
      'native': emitNativeDeclarations(validateNative(module)),
    };
    for (final entry in declarations.entries) {
      await File('${directory.path}/${entry.key}.d.mts')
          .writeAsString(entry.value);
      await File('${directory.path}/${entry.key}-consumer.mts').writeAsString(
        r'''
import * as api from './BACKEND.mjs';
const value: number = api.run((n, s) => n + s.length);
const big: bigint = api.big(n => n + 1n);
api.optional(); api.optional(undefined); api.optional(null);
api.record(r => [r.$1, r.text.length]);
const calls = new api.Calls(() => {});
calls.run(n => n * 2);
// @ts-expect-error A borrowed callback is required.
api.run();
// @ts-expect-error Callback result must match its Dart result.
api.run(() => 'wrong');
// @ts-expect-error A callback cannot narrow its input to a different scalar.
api.run((n: string, s: string) => n.length + s.length);
// @ts-expect-error A declared synchronous result does not accept a Promise.
api.run(async n => n);
// @ts-expect-error The callback uses the enclosing bigint policy.
api.big((n: number) => n);
// @ts-expect-error Nullable applies to the callback, not its result.
api.optional(() => null);
// @ts-expect-error Record and list child types remain exact.
api.record(r => [r.text]);
// @ts-expect-error Members retain callback result validation.
calls.run(() => 'wrong');
void [value, big];
'''
            .replaceAll('BACKEND', entry.key),
      );
    }
    final tsc =
        Platform.environment['NAPI_TSC'] ??
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
    for (final mode in ['NodeNext', 'Bundler']) {
      final result = await Process.run(Platform.environment['NODE'] ?? 'node', [
        tsc,
        '--ignoreConfig',
        '--noEmit',
        '--strict',
        '--target',
        'ES2022',
        '--module',
        mode == 'NodeNext' ? 'NodeNext' : 'ESNext',
        '--moduleResolution',
        mode,
        for (final backend in declarations.keys)
          '${directory.path}/$backend-consumer.mts',
      ]);
      expect(
        result.exitCode,
        0,
        reason: '$mode: ${result.stdout}${result.stderr}',
      );
    }
  });

  final rejected = <String, String>{
    'callback output': '@NAPI() int Function(int) output() => (n) => n;',
    'callback getter': '@NAPI() class Bad { Bad(); int Function(int) get callback => (n) => n; }',
    'callback field':
        '@NAPI() class Bad { Bad(); int Function(int) callback = (n) => n; }',
    'nested outer List':
        '@NAPI() int run(List<int Function()> callbacks) => 1;',
    'nested outer record': '@NAPI() int run((int Function(),) callbacks) => 1;',
    'nested callback parameter':
        '@NAPI() int run(int Function(void Function()) callback) => 1;',
    'nested callback result':
        '@NAPI() int run(int Function() Function() callback) => 1;',
    'optional callback parameter':
        '@NAPI() int run(int Function([int?]) callback) => 1;',
    'named callback parameter':
        '@NAPI() int run(int Function({required int value}) callback) => 1;',
    'generic callback': '@NAPI() int run(T Function<T>(T) callback) => 1;',
    'untyped Function': '@NAPI() int run(Function callback) => 1;',
    'callback Future result':
        '@NAPI() int run(Future<int> Function(int) callback) => 1;',
    'callback FutureOr result': "import 'dart:async'; @NAPI() int run(FutureOr<int> Function(int) callback) => 1;",
    'outer Future': '@NAPI() Future<int> run(int Function(int) callback) => Future.value(1);',
    'async outer':
        '@NAPI() Future<void> run(void Function() callback) async {}',
    'outer Future member': '@NAPI() class Bad { Bad(); Future<int> run(int Function(int) callback) => Future.value(1); }',
    'cleanup delayed by mapping': "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') class Bad { Bad(); void close(void Function() callback) {} }",
    'Map callback parameter':
        '@NAPI() int run(int Function(Map<String, int>) callback) => 1;',
    'Dictionary callback result':
        '@NAPI() int run(Dictionary<int> Function() callback) => 1;',
    'reference callback parameter': '@NAPI() class Box { Box(); } @NAPI() int run(int Function(Box) callback) => 1;',
    'reference callback result': '@NAPI() class Box { Box(); } @NAPI() int run(Box Function() callback) => 1;',
    'value callback result': '@NAPI(classPolicy: ClassPolicy.value) class Box { int value = 1; } @NAPI() int run(Box Function() callback) => 1;',
    'dynamic callback payload':
        '@NAPI() int run(dynamic Function(dynamic) callback) => 1;',
  };
  for (final entry in rejected.entries) {
    test('rejects ${entry.key} in both backends', () async {
      final module = await read(entry.value);
      final diagnostic = throwsA(
        isA<BindingDiagnostic>().having((e) => e.code, 'code', 'NAPI_CALLBACK'),
      );
      expect(() => validate(module), diagnostic);
      expect(() => validateNative(module), diagnostic);
    });
  }

  test('opaque logical payloads are not callable signature payloads', () {
    final source = SourceLocation(Uri.file('/callbacks.dart'), 0, 1);
    final parameter = DeclarationId(
      source.uri,
      'T',
      kind: DeclarationKind.typeParameter,
    );
    final type = TypeParameterType(parameter);
    expect(
      () => validateValueType(
        FunctionTypeBinding(
          result: type,
          parameters: [ParameterBinding('value', type)],
        ),
        source,
        direction: ValueDirection.input,
        opaqueParameters: {parameter},
        allowCallback: true,
      ),
      throwsA(
        isA<BindingDiagnostic>().having((e) => e.code, 'code', 'NAPI_CALLBACK'),
      ),
    );
  });
}
