import 'dart:io';

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
typedef Payload = ({List<DartBox?>? boxes, Map<String, int?>? counts});
@NAPI() Map<String?, List<Payload?>?>? nested(Map<String?, List<Payload?>?>? value) => value;
@NAPI() Map<DartBox?, DartBox?> references(Map<DartBox?, DartBox?> value) => value;
@NAPI(bigint: true) Map<int, Map<String, BigInt?>> wide(Map<int, Map<String, BigInt?>> value) => value;
@NAPI() Map<String, int>? optional([Map<String, int>? value]) => value;
@NAPI() Map<String, int> requiredNamed({required Map<String, int> value}) => value;
@NAPI() Map<String, int> mixed(Map<String, int> value, [int extra = 0]) => value;
class CustomMap extends MapBase<String, int> {
  int? operator [](Object? key) => throw StateError('lookup failed');
  void operator []=(String key, int value) => throw UnimplementedError();
  void clear() => throw UnimplementedError();
  int? remove(Object? key) => throw UnimplementedError();
  Iterable<String> get keys => throw StateError('keys failed');
  int get length => throw StateError('length failed');
  Iterable<MapEntry<String, int>> get entries => throw StateError('entries failed');
}
@NAPI() Map<String, int> custom() => CustomMap();
@NAPI(name: 'Box')
class DartBox {
  DartBox(this.id);
  final int id;
}
@NAPI(name: 'Group')
class DartGroup {
  DartGroup(Map<String, DartBox?> members) : _members = members;
  @NAPI(name: 'from')
  DartGroup.named({Map<String, DartBox?>? members}) : _members = members ?? {};
  Map<String, DartBox?> _members;
  Map<String, DartBox?> get members => _members;
  set members(Map<String, DartBox?> next) { _members = next; }
  Map<String, List<DartBox?>?> mirror(Map<String, List<DartBox?>?> value) => value;
  Map<String, DartBox?>? maybe([Map<String, DartBox?>? value]) => value;
  Map<String, DartBox?> select({required Map<String, DartBox?> value}) => value;
  void take(Map<String, DartBox?> value) { _members = value; }
  static Map<String, DartBox?> echo(Map<String, DartBox?> value) => value;
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
    directory = await Directory.systemTemp.createTemp('napi-native-map-');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<NativeModulePlan> read() async {
    final input = File('${directory.path}/business.dart');
    await input.writeAsString(_source);
    return validateNative(
      await AnnotationFrontend(
        packagesPath: _packages,
        native: true,
      ).read(input.uri),
    );
  }

  test(
    'native Map plans retain nested nullability and reference policies',
    () async {
      final plan = await read();
      final nested = plan.functions.first.inputs.single as MapConversion;
      expect(nested.nullable, isTrue);
      expect(nested.key.nullable, isTrue);
      final list = nested.value as ListConversion;
      expect(list.nullable, isTrue);
      final record = list.element as RecordConversion;
      expect(record.nullable, isTrue);
      final boxes = record.named['boxes'] as ListConversion;
      final box = boxes.element as ReferenceConversion;
      expect(box.nullable, isTrue);
      expect(box.classId, 0);
      expect(box.classBinding.exportName, 'Box');
      final counts = record.named['counts'] as MapConversion;
      expect(counts.nullable, isTrue);
      expect(counts.value.nullable, isTrue);
      final references = plan.functions[1].inputs.single as MapConversion;
      expect((references.key as ReferenceConversion).classId, 0);
      expect((references.value as ReferenceConversion).classId, 0);
      final wide = plan.functions[2].inputs.single as MapConversion;
      expect((wide.key as ScalarConversion).usesBigInt, isTrue);
      expect(
        ((wide.value as MapConversion).value as ScalarConversion).usesBigInt,
        isTrue,
      );
      final group = plan.classes[1];
      expect(group.constructor.inputs.single, isA<MapConversion>());
      for (final member in group.members) {
        expect(member.inputs.every((input) => input is MapConversion), isTrue);
        if (member.output != null && member.exportName != 'from') {
          expect(member.output, isA<MapConversion>());
        }
      }
    },
  );

  test('native Map generation snapshots before converting entries', () async {
    final plan = await read();
    final dart = emitNativeDart(plan);
    expect(dart, contains("import 'dart:ffi';"));
    expect(
      dart,
      contains(
        '_api.snapshotMap(env, value, path, 10000 - state.work, depth, state.contains(env, value))',
      ),
    );
    expect(
      dart,
      contains("_api.readOwnValue(env, entries, '\${2 * i}', keyPath)"),
    );
    expect(
      dart,
      contains("_api.readOwnValue(env, entries, '\${2 * i + 1}', valuePath)"),
    );
    expect(dart, contains('if (length > (10000 - state.work) ~/ 2)'));
    expect(dart, contains("\$path.length: expected a Map length"));
    expect(dart, contains("\$path: Map length changed during iteration"));
    expect(dart, contains('if (length < 0 || length > 0xffffffff)'));
    expect(dart, contains('final iterator = value.entries.iterator;'));
    expect(dart, contains('entries.add((entry.key, entry.value));'));
    expect(
      dart,
      contains(
        "if (iterator.moveNext()) throw NapiTypeError('\$path: Map length changed during iteration');\n    final result = _api.createMap(env);",
      ),
    );
    expect(
      RegExp(
        r'final key = _writeNativeStructure[^\n]+\n'
        r'      final child = _writeNativeStructure[^\n]+\n'
        r'      _api.checkedInsertMap\(env, result, key, child, keyPath\);',
      ).hasMatch(dart),
      isTrue,
    );
    expect(
      dart,
      contains(
        "if (result.containsKey(key)) throw NapiTypeError('\$keyPath: duplicate converted Map key');\n      result[key] = child;",
      ),
    );
    expect(dart, contains('_api.ownerValue(env, value, path, 0)'));
    expect(dart, contains('is! target.DartBox'));
    expect(
      dart,
      contains('_api.referenceResult(env, value, 0, path, state.pending)'),
    );
    expect(dart, contains('finally { state.active.removeLast(); }'));
    expect(dart, contains('finally { state.leave(value); }'));
    final nested = _callback(dart, plan.functions.first);
    expect(nested, contains('call.argumentCount > 0 ? call.arguments[0]'));
    expect(nested, contains('_api.rollbackReferences(state.pending)'));
    expect(nested, isNot(contains('if (value == null)')));
    expect(
      _callback(dart, plan.functions[4]),
      contains(
        '_api.requiredOption(call.env, options, 0, "requiredNamed.value")',
      ),
    );
    expect(
      _callback(dart, plan.functions[5]),
      contains('_api.requiredArgument(call, 0, "mixed.value")'),
    );
  });

  test(
    'Map class calls retain receiver checks, defaults and void results',
    () async {
      final plan = await read();
      final dart = emitNativeDart(plan);
      final group = plan.classes[1];
      final constructor = _callback(dart, group.constructor);
      expect(
        constructor,
        contains('_api.requiredArgument(call, 0, "Group.members")'),
      );
      expect(constructor, isNot(contains('call.argumentCount >')));
      final mirror = _callback(
        dart,
        group.members.singleWhere((call) => call.exportName == 'mirror'),
      );
      expect(
        mirror,
        contains('_api.ownerValue(call.env, call.self, "Group.mirror", 1)'),
      );
      expect(
        mirror.indexOf('ownerValue('),
        lessThan(mirror.indexOf('requiredArgument(')),
      );
      expect(mirror, isNot(contains('call.argumentCount >')));
      expect(mirror, contains('"Group.mirror result"'));
      final from = _callback(
        dart,
        group.members.singleWhere((call) => call.exportName == 'from'),
      );
      expect(from, contains('_api.defaultOption(call.env, options, 0)'));
      expect(from, contains('target.DartGroup.named(members: a0)'));
      final maybe = _callback(
        dart,
        group.members.singleWhere((call) => call.exportName == 'maybe'),
      );
      expect(maybe, contains('_api.omittedOrUndefined(call, 0)'));
      expect(maybe, contains('a0 = null;'));
      for (final call in group.members.where(
        (call) =>
            call.kind == NativeCallKind.setter || call.exportName == 'take',
      )) {
        final body = _callback(dart, call);
        expect(body, contains('return _api.undefinedResult(call.env);'));
        expect(body, isNot(contains('_writeNativeStructure')));
      }
      final echo = _callback(
        dart,
        group.members.singleWhere((call) => call.exportName == 'echo'),
      );
      expect(echo, isNot(contains('ownerValue(call.env, call.self')));
      expect(
        echo,
        contains('_api.requiredArgument(call, 0, "Group.echo.value")'),
      );
    },
  );

  test(
    'native Map functions and class members compile as actual AOT',
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

  test('native Map declarations compile for a TypeScript consumer', () async {
    final types = emitNativeDeclarations(await read());
    expect(types, contains('globalThis.Map<string | null,'));
    expect(types, contains('globalThis.Map<Box | null, Box | null>'));
    expect(
      types,
      contains('globalThis.Map<bigint, globalThis.Map<string, bigint | null>>'),
    );
    expect(
      types,
      contains('constructor(members: globalThis.Map<string, Box | null>);'),
    );
    expect(
      types,
      contains('set members(next: globalThis.Map<string, Box | null>);'),
    );
    expect(
      types,
      contains('take(value: globalThis.Map<string, Box | null>): void;'),
    );
    await File('${directory.path}/module.d.mts').writeAsString(types);
    final consumer = File('${directory.path}/consumer.mts');
    await consumer.writeAsString('''
import {Box, Group, nested, references, wide, optional, requiredNamed, mixed} from './module.mjs';
const box = new Box(1);
const members = new Map<string, Box | null>([['box', box], ['none', null]]);
const group = new Group(members);
nested(new Map([[null, [{boxes: [box, null], counts: new Map([['n', null]])}, null]]]));
nested(null);
references(new Map([[box, null], [null, box]]));
wide(new Map([[42n, new Map([['huge', 1n << 200n]])]]));
optional(); optional(undefined); optional(null);
requiredNamed({value: new Map([['n', 1]])});
mixed(new Map([['n', 1]]));
group.members = members; group.mirror(new Map([['list', [box, null]]]));
group.maybe(); group.maybe(undefined); group.maybe(null);
group.select({value: members}); group.take(members); Group.echo(members);
const from: Group = Group.from({members: undefined});
// @ts-expect-error Map keys retain the selected bigint policy.
wide(new Map([[1, new Map([['huge', 1n]])]]));
// @ts-expect-error Selected reference Map keys retain their public type.
references(new Map([[1, null]]));
// @ts-expect-error A required named Map argument remains required.
group.select({});
void from;
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
