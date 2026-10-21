import 'dart:io';

import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;
const _source = '''
import 'package:napi/napi.dart';
typedef Nested = ({DartBox? head, List<DartBox?>? tail});
@NAPI() List<Nested?>? nested(List<Nested?>? value) => value;
@NAPI(name: 'Box')
class DartBox {
  DartBox(this.id);
  final int id;
}
@NAPI(name: 'Group')
class DartGroup {
  DartGroup(List<DartBox?> members) : _members = members;
  @NAPI(name: 'from')
  DartGroup.named({List<DartBox?>? members}) : _members = members ?? [];
  List<DartBox?> _members;
  List<DartBox?> get members => _members;
  set members(List<DartBox?> next) { _members = next; }
  List<Nested?> mirror(List<Nested?> value) => value;
  List<DartBox?>? maybe([List<DartBox?>? value]) => value;
  List<DartBox?> select({required List<DartBox?> value}) => value;
  void take(List<DartBox?> values) { _members = values; }
  static List<DartBox?> echo(List<DartBox?> members) => members;
}
''';

String _callback(String source, NativeCallPlan call) {
  final start = source.indexOf('int ${call.callback}(');
  final end = source.indexOf('\n}', start);
  if (start < 0 || end < 0) throw StateError('Missing generated callback');
  return source.substring(start, end + 2);
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'napi-native-structural-reference-',
    );
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<NativeModulePlan> read([String source = _source]) async {
    final file = File('${directory.path}/business.dart');
    await file.writeAsString(source);
    return validateNative(
      await AnnotationFrontend(
        packagesPath: _packages,
        native: true,
      ).read(file.uri),
    );
  }

  test(
    'nested native conversions retain selected reference identity',
    () async {
      final plan = await read();
      final list = plan.functions.single.inputs.single as ListConversion;
      final record = list.element as RecordConversion;
      final head = record.named['head'] as ReferenceConversion;
      final tail = record.named['tail'] as ListConversion;
      final tailLeaf = tail.element as ReferenceConversion;
      expect(list.nullable, isTrue);
      expect(record.nullable, isTrue);
      expect(head.nullable, isTrue);
      expect(tail.nullable, isTrue);
      expect(tailLeaf.nullable, isTrue);
      expect(head.classId, 0);
      expect(tailLeaf.classId, head.classId);
      expect(head.classBinding.exportName, 'Box');
      expect(head.dartType, 'target.DartBox?');

      final group = plan.classes[1];
      expect(group.constructor.inputs.single, isA<ListConversion>());
      final from = group.members.singleWhere(
        (call) => call.exportName == 'from',
      );
      expect(from.isStatic, isTrue);
      expect((from.output as ReferenceConversion).classId, 1);
      expect(from.javascriptArity, 0);
      final mirror = group.members.singleWhere(
        (call) => call.exportName == 'mirror',
      );
      expect(mirror.inputs.single, isA<ListConversion>());
      expect(mirror.output, isA<ListConversion>());
      expect(mirror.classId, 1);
      final members = group.members.where(
        (call) => call.exportName == 'members',
      );
      expect(members.map((call) => call.kind), [
        NativeCallKind.getter,
        NativeCallKind.setter,
      ]);
      expect(members.first.output, isA<ListConversion>());
      expect(members.last.inputs.single, isA<ListConversion>());
      expect(members.last.output, isNull);
    },
  );

  test(
    'native reference leaves use runtime paths and class calls retain presence',
    () async {
      final plan = await read();
      final dart = emitNativeDart(plan);
      expect(dart, contains('_api.ownerValue(env, value, path, 0)'));
      expect(dart, contains('is! target.DartBox'));
      expect(
        dart,
        contains('_api.referenceResult(env, value!, 0, path, state.pending)'),
      );
      expect(dart, contains('final pending = <(Object, int)>[];'));

      final direct = _callback(dart, plan.functions.single);
      expect(direct, contains('call.argumentCount > 0 ? call.arguments[0]'));
      expect(direct, contains('final state = _NativeWriteState();'));
      expect(direct, contains('_api.rollbackReferences(state.pending);'));
      expect(direct, contains('rethrow;'));
      final group = plan.classes[1];
      final constructor = _callback(dart, group.constructor);
      expect(
        constructor,
        contains('_api.requiredArgument(call, 0, "Group.members")'),
      );
      expect(constructor, isNot(contains('call.argumentCount >')));
      expect(
        constructor,
        contains('_api.wrap(call, target.DartGroup(a0), 1, "Group")'),
      );

      final mirror = _callback(
        dart,
        group.members.singleWhere((call) => call.exportName == 'mirror'),
      );
      expect(
        mirror,
        contains('_api.ownerValue(call.env, call.self, "Group.mirror", 1)'),
      );
      expect(
        mirror,
        contains('_api.requiredArgument(call, 0, "Group.mirror.value")'),
      );
      expect(
        mirror.indexOf('ownerValue('),
        lessThan(mirror.indexOf('requiredArgument(')),
      );
      expect(mirror, contains('"Group.mirror result"'));
      expect(mirror, isNot(contains('call.argumentCount >')));

      final echo = _callback(
        dart,
        group.members.singleWhere((call) => call.exportName == 'echo'),
      );
      expect(
        echo,
        contains('_api.requiredArgument(call, 0, "Group.echo.members")'),
      );
      expect(echo, isNot(contains('ownerValue(call.env, call.self')));
      expect(echo, isNot(contains('call.argumentCount >')));

      final select = _callback(
        dart,
        group.members.singleWhere((call) => call.exportName == 'select'),
      );
      expect(
        select,
        contains(
          '_api.requiredOption(call.env, options, 0, "Group.select.value")',
        ),
      );
      final maybe = _callback(
        dart,
        group.members.singleWhere((call) => call.exportName == 'maybe'),
      );
      expect(maybe, contains('_api.omittedOrUndefined(call, 0)'));
      expect(maybe, contains('a0 = null;'));
      final from = _callback(
        dart,
        group.members.singleWhere((call) => call.exportName == 'from'),
      );
      expect(from, contains('_api.defaultOption(call.env, options, 0)'));
      expect(from, contains('target.DartGroup.named(members: a0)'));

      final setter = _callback(
        dart,
        group.members.singleWhere(
          (call) =>
              call.exportName == 'members' &&
              call.kind == NativeCallKind.setter,
        ),
      );
      expect(
        setter,
        contains('_api.requiredArgument(call, 0, "Group.members.next")'),
      );
      expect(setter, contains('object.members = a0;'));
      expect(setter, contains('return _api.undefinedResult(call.env);'));
      expect(setter, isNot(contains('_writeNativeStructure')));
      final take = _callback(
        dart,
        group.members.singleWhere((call) => call.exportName == 'take'),
      );
      expect(take, contains('object.take(a0);'));
      expect(take, contains('return _api.undefinedResult(call.env);'));
      expect(take, isNot(contains('_writeNativeStructure')));
    },
  );

  test(
    'nested references and class structural members compile as actual AOT',
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

  test('pure copied reference and opaque handles compile with and without resources', () async {
    const source = '''
import 'dart:typed_data';
import 'package:napi/napi.dart';
typedef Copy<T> = ({
  T payload,
  List<Box?> items,
  Map<Box, Dictionary<List<Box?>>> groups,
  JsArray<Dictionary<T>> nested,
  Uint8List bytes,
});
@NAPI()
class Box {
  Box(this.id);
  final int id;
}
@NAPI()
class Payloads<T> {
  Payloads(this.source);
  final JsArray<Copy<T>> source;
  JsArray<Copy<T>> roundtrip() {
    final next = source.get(0);
    if (next != null) source.set(0, next);
    return source;
  }
  JsMap<({Box ref, List<int> ids}), Dictionary<JsArray<List<Box>>>> maps(
    JsMap<({Box ref, List<int> ids}), Dictionary<JsArray<List<Box>>>> value,
  ) => value;
  Future<JsArray<Copy<T>>> observe(
    Future<JsArray<Copy<T>>> Function() read,
  ) => read();
}
''';
    for (final resources in [false, true]) {
      final plan = await read(
        source +
            (resources
                ? '''
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource extends Box {
  Resource(super.id);
  void close() {}
}
'''
                : ''),
      );
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
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('native declarations preserve nested public reference types', () async {
    final types = emitNativeDeclarations(await read());
    expect(types, contains('head: Box | null'));
    expect(types, contains('tail: Array<Box | null> | null'));
    expect(types, contains('constructor(members: ReadonlyArray<Box | null>);'));
    expect(types, contains('get members(): Array<Box | null>;'));
    expect(types, contains('set members(next: ReadonlyArray<Box | null>);'));
    expect(
      types,
      contains(
        'static from(options?: { members?: ReadonlyArray<Box | null> | null | undefined }): Group;',
      ),
    );
    expect(types, contains('take(values: ReadonlyArray<Box | null>): void;'));
    await File('${directory.path}/module.d.mts').writeAsString(types);
    final consumer = File('${directory.path}/consumer.mts');
    await consumer.writeAsString('''
import {Box, Group, nested} from './module.mjs';
const box = new Box(1);
const group = new Group([box, null]);
const copied = nested([{head: box, tail: [box, null]}, null]);
group.members = [box, null];
group.mirror([{head: null, tail: [box]}]);
group.maybe(); group.maybe(undefined); group.maybe(null);
group.select({value: [box]});
group.take([box, null]);
Group.echo([box]);
const from: Group = Group.from({members: undefined});
// @ts-expect-error A reference leaf keeps its selected public type.
nested([{head: 1, tail: null}]);
// @ts-expect-error A required structural named argument is required.
group.select({});
void [copied, from];
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
}
