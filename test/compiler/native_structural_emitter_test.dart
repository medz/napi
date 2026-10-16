import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;
const _source = '''
import 'dart:collection';
import 'package:napi/napi.dart';
typedef Item = (String, {List<int?>? values, ({bool flag, double ratio})? detail});
@NAPI() List<List<int?>?>? lists(List<List<int?>?>? value) => value;
@NAPI() List<Item?> records(List<Item?> value) => value;
@NAPI(bigint: true) List<({int wide, BigInt huge})> bigints(List<({int wide, BigInt huge})> value) => value;
@NAPI() List<int?>? optional([List<int?>? value]) => value;
@NAPI() List<bool>? named({List<bool>? value}) => value;
@NAPI() () empty(() value) => value;
@NAPI() (int,) single((int,) value) => value;
class ThrowingList extends ListBase<int> {
  int get length => throw StateError('length failed');
  set length(int value) => throw UnimplementedError();
  int operator [](int index) => throw StateError('element failed');
  void operator []=(int index, int value) => throw UnimplementedError();
}
@NAPI() List<int> throwing() => ThrowingList();
@NAPI() List<int> requiredNamed({required List<int> value}) => value;
@NAPI() List<int> mixed(List<int> value, [int extra = 0]) => value;
@NAPI() class Ref { Ref(); }
@NAPI() Ref reference(List<int> value) => Ref();
''';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'napi-native-structural-emitter-',
    );
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<NativeModulePlan> read([String text = _source]) async {
    final input = File('${directory.path}/business.dart');
    await input.writeAsString(text);
    return validateNative(
      await AnnotationFrontend(
        packagesPath: _packages,
        native: true,
      ).read(input.uri),
    );
  }

  test(
    'top-level native plans reuse nested List and record conversions',
    () async {
      final plan = await read();
      expect(plan.functions, hasLength(11));
      final lists = plan.functions.first;
      final list = lists.inputs.single as ListConversion;
      expect(list.nullable, isTrue);
      expect(list.element, isA<ListConversion>());
      expect((list.element as ListConversion).element.nullable, isTrue);
      final record =
          ((plan.functions[1].inputs.single as ListConversion).element
              as RecordConversion);
      expect(record.nullable, isTrue);
      expect(record.positional.single, isA<ScalarConversion>());
      expect(record.named['values'], isA<ListConversion>());
      final bigints =
          (plan.functions[2].inputs.single as ListConversion).element
              as RecordConversion;
      expect((bigints.named['wide'] as ScalarConversion).usesBigInt, isTrue);
      expect((bigints.named['huge'] as ScalarConversion).usesBigInt, isTrue);
      expect(plan.functions[3].javascriptArity, 0);
      expect(plan.functions[4].javascriptArity, 0);
    },
  );

  test(
    'native traversal keeps bounded state and reads children lazily',
    () async {
      final dart = emitNativeDart(await read());
      expect(dart, contains("import 'dart:ffi';"));
      expect(dart, contains('final active = <Pointer<Void>>[];'));
      expect(dart, contains('_api.strictEquals(env, value, ancestor)'));
      expect(dart, contains('final active = Set<Object>.identity();'));
      expect(dart, contains('if (++work > 10000)'));
      expect(dart, contains('if (depth >= 64)'));
      expect(dart, contains('if (length < 0 || length > 0xffffffff)'));
      expect(dart, contains('if (length > 10000 - state.work)'));
      expect(dart, contains('finally { state.active.removeLast(); }'));
      expect(dart, contains('finally { state.leave(value); }'));
      expect(dart, contains('state.contains(env, value)'));
      expect(
        dart,
        contains(
          'call.argumentCount > 0 ? call.arguments[0] : Pointer<Void>.fromAddress(_api.undefinedResult(call.env))',
        ),
      );
      expect(
        dart,
        contains(
          '_api.requiredOption(call.env, options, 0, "requiredNamed.value")',
        ),
      );
      expect(dart, contains('_api.requiredArgument(call, 0, "mixed.value")'));
      expect(
        dart,
        contains('_api.requiredArgument(call, 0, "reference.value")'),
      );
      expect(
        dart,
        contains('_api.readOwnValue(env, value, \'\$i\', childPath)'),
      );
      expect(
        dart,
        contains('_api.defineOwnValue(env, result, \'\$i\', child)'),
      );
      expect(dart, contains('_api.integer(env, value, path, nullable: true)'));
      expect(dart, contains('_api.integerBigInt(env, value, path)'));
      expect(dart, contains('_api.bigInteger(env, value, path)'));
      expect(dart, contains('_api.string(env, value, path)'));
      expect(dart, contains('_api.boolean(env, value, path)'));
      expect(dart, contains('_api.doubleValue(env, value, path)'));
      expect(dart, contains('path + ".\\\$1"'));
      // A later sibling descriptor is inspected only after the previous child's
      // conversion has completed, preserving Proxy trap/error order.
      expect(
        RegExp(
          r'final raw0 = _api\.readOwnValue[^\n]+\n'
          r'    final child0 = _readNativeStructure[^\n]+\n'
          r'    final raw1 = _api\.readOwnValue',
        ).hasMatch(dart),
        isTrue,
      );
      expect(dart, isNot(contains('value.address == ancestor.address')));
    },
  );

  test('native structural declarations compile for a TypeScript consumer', () async {
    final types = emitNativeDeclarations(await read());
    expect(types, contains('Array<Array<number | null> | null> | null'));
    expect(types, contains('wide: bigint'));
    expect(types, contains('huge: bigint'));
    expect(types, contains('optional: (value?: Array<number | null> | null)'));
    expect(types, contains('Record<PropertyKey, never>'));
    await File('${directory.path}/module.d.mts').writeAsString(types);
    final consumer = File('${directory.path}/consumer.mts');
    await consumer.writeAsString('''
import {lists, records, bigints, optional, named, empty, single} from './module.mjs';
lists([[1, null], null]);
lists(null);
records([{\$1: 'text', values: [1, null], detail: {flag: true, ratio: 1.5}}, null]);
bigints([{wide: 42n, huge: 1n << 200n}]);
optional(); optional(undefined); optional(null);
named({value: [true, false]}); named({value: undefined});
empty({}); single({\$1: 1});
// @ts-expect-error Nested elements retain strict scalar types.
lists([[true]]);
// @ts-expect-error Record fields retain their selected bigint policy.
bigints([{wide: 42, huge: 1n}]);
''');
    final tsc =
        Platform.environment['NAPI_TSC'] ??
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
    expect(File(tsc).existsSync(), isTrue);
    final compilation = await Process.run('node', [
      tsc,
      '--ignoreConfig',
      '--strict',
      '--exactOptionalPropertyTypes',
      '--noEmit',
      '--target',
      'ES2022',
      '--module',
      'NodeNext',
      '--moduleResolution',
      'NodeNext',
      consumer.path,
    ]);
    expect(
      compilation.exitCode,
      0,
      reason: '${compilation.stdout}${compilation.stderr}',
    );
  });

  test(
    'native structural arguments and results compile as actual AOT',
    () async {
      final entry = File('${directory.path}/entry.dart');
      await entry.writeAsString(emitNativeDart(await read()));
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
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final (description, declaration, code) in [
    (
      'Set leaves',
      '@NAPI() List<Set<int>> bad(List<Set<int>> value) => value;',
      'NAPI_TYPE',
    ),
    (
      'unselected reference leaves',
      'class Ref {} @NAPI() List<Ref> bad(List<Ref> value) => value;',
      'NAPI_TYPE',
    ),
    (
      'non-null structural defaults',
      '@NAPI() class Bad { List<int> method([List<int> value = const []]) => value; }',
      'NAPI_DEFAULT',
    ),
  ]) {
    test('$description stay diagnostic', () async {
      expect(
        () => read("import 'package:napi/napi.dart';\n$declaration"),
        throwsA(
          isA<BindingDiagnostic>()
              .having((e) => e.code, 'code', code)
              .having(
                (e) => e.source?.uri.path,
                'source',
                endsWith('business.dart'),
              ),
        ),
      );
    });
  }
}
