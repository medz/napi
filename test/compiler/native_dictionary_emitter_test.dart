import 'dart:io';

import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:napi/src/compiler/native/structural.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;
const _source = '''
import 'dart:collection';
import 'package:napi/napi.dart' as api;
typedef Alias<T> = api.Dictionary<T>;
typedef Payload = ({Alias<DartBox?>? members, Map<String, List<int?>?> maps});
@api.NAPI() Alias<int?> direct(Alias<int?> value) => value;
@api.NAPI() List<Alias<Payload?>?>? nested(List<Alias<Payload?>?>? value) => value;
@api.NAPI(bigint: true) Alias<({int wide, BigInt? huge})> wide(Alias<({int wide, BigInt? huge})> value) => value;
@api.NAPI() Alias<int>? optional([Alias<int>? value]) => value;
@api.NAPI() Alias<int> requiredNamed({required Alias<int> value}) => value;
@api.NAPI() (Map<String, int>, Alias<int>) mixed(Map<String, int> map, Alias<int> dictionary) => (map, dictionary);
class CustomMap extends MapBase<String, int> {
  int? operator [](Object? key) => throw StateError('lookup failed');
  void operator []=(String key, int value) => throw UnimplementedError();
  void clear() => throw UnimplementedError();
  int? remove(Object? key) => throw UnimplementedError();
  Iterable<String> get keys => throw StateError('keys failed');
  int get length => throw StateError('length failed');
  Iterable<MapEntry<String, int>> get entries => throw StateError('entries failed');
}
@api.NAPI() Alias<int> custom() => api.Dictionary<int>(CustomMap());
@api.NAPI(name: 'Box')
class DartBox {
  DartBox(this.id);
  final int id;
}
@api.NAPI(name: 'Group')
class DartGroup {
  DartGroup(Alias<DartBox?> members) : _members = members;
  @api.NAPI(name: 'from')
  DartGroup.named({Alias<DartBox?>? members})
      : _members = members ?? api.Dictionary<DartBox?>({});
  Alias<DartBox?> _members;
  Alias<DartBox?> get members => _members;
  set members(Alias<DartBox?> next) { _members = next; }
  Alias<List<DartBox?>?> mirror(Alias<List<DartBox?>?> value) => value;
  Alias<DartBox?>? maybe([Alias<DartBox?>? value]) => value;
  Alias<DartBox?> select({required Alias<DartBox?> value}) => value;
  void take(Alias<DartBox?> value) { _members = value; }
  static Alias<DartBox?> echo(Alias<DartBox?> value) => value;
}
@api.NAPI(name: 'UserDictionary')
class Dictionary {
  Dictionary(this.id);
  final int id;
}
typedef UserAlias = Dictionary;
@api.NAPI() UserAlias user(UserAlias value) => value;
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
      'napi-native-dictionary-',
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
    'native Dictionary plans distinguish Maps and selected class aliases',
    () async {
      final plan = await read();
      final direct = plan.functions.first.inputs.single as DictionaryConversion;
      expect(direct.value, isA<ScalarConversion>());
      expect(direct.value.nullable, isTrue);
      expect(direct.dartType, 'napi.Dictionary<int?>');
      final nested = plan.functions[1].inputs.single as ListConversion;
      expect(nested.nullable, isTrue);
      final dictionary = nested.element as DictionaryConversion;
      expect(dictionary.nullable, isTrue);
      final record = dictionary.value as RecordConversion;
      expect(record.nullable, isTrue);
      final members = record.named['members'] as DictionaryConversion;
      final box = members.value as ReferenceConversion;
      expect(members.nullable, isTrue);
      expect(box.nullable, isTrue);
      expect(box.classId, 0);
      expect(box.classBinding.exportName, 'Box');
      expect(record.named['maps'], isA<MapConversion>());
      final wide = plan.functions[2].inputs.single as DictionaryConversion;
      expect(
        ((wide.value as RecordConversion).named['wide'] as ScalarConversion)
            .usesBigInt,
        isTrue,
      );
      final mixed = plan.functions[5];
      expect(mixed.inputs[0], isA<MapConversion>());
      expect(mixed.inputs[1], isA<DictionaryConversion>());
      final user = plan.functions.last.inputs.single as ReferenceConversion;
      expect(user.classId, 2);
      expect(user.classBinding.exportName, 'UserDictionary');
      expect(user.dartType, 'target.Dictionary');
      expect(
        plan.classes[1].constructor.inputs.single,
        isA<DictionaryConversion>(),
      );
    },
  );

  test(
    'Dictionary metadata keys do not create scalar conversion visits',
    () async {
      final conversion = (await read()).functions.first.inputs.single;
      final reader = NativeStructuralEmitter()..read(conversion);
      final writer = NativeStructuralEmitter()..write(conversion);
      for (final source in [reader.source, writer.source]) {
        // Only the Dictionary node and its value consume structural work.
        expect('state.visit(path);'.allMatches(source), hasLength(2));
        expect(source, isNot(contains('containsKey(')));
        expect(source, isNot(contains('checkedInsertMap(')));
      }
      expect(
        reader.source,
        contains(
          '_api.dictionaryKeys(env, value, path, 10000 - state.work, depth, state.contains(env, value))',
        ),
      );
      expect(reader.source, contains('_api.string(env, rawKey, path)'));
      expect(reader.source, contains('return napi.Dictionary<int?>(result)'));
      expect(
        reader.source,
        contains('_api.readOwnValue(env, value, key, childPath)'),
      );
      expect(
        reader.source,
        contains(r"final childPath = '$path[${jsonEncode(key)}]';"),
      );
      expect(
        writer.source,
        contains('final entries = List<Object?>.filled(length * 2, null);'),
      );
      expect(writer.source, contains('final keys = <String>{};'));
      expect(writer.source, contains('if (length > 10000 - state.work)'));
      expect(writer.source, contains('if (length < 0 || length > 0xffffffff)'));
      expect(
        writer.source,
        contains(r'$path.length: expected a Dictionary length'),
      );
      expect(
        writer.source,
        contains(r'$path: Dictionary length changed during iteration'),
      );
      expect(
        writer.source,
        contains(r'$path[${jsonEncode(key)}]: duplicate Dictionary key'),
      );
      expect(
        writer.source.indexOf('if (!keys.add(key))'),
        lessThan(writer.source.indexOf('_api.createDictionary(env)')),
      );
      expect(
        writer.source.indexOf('if (iterator.moveNext())'),
        lessThan(writer.source.indexOf('_api.createDictionary(env)')),
      );
      expect(
        writer.source,
        contains('_api.defineOwnValue(env, result, key, child)'),
      );
      expect(reader.source, contains('finally { state.active.removeLast(); }'));
      expect(writer.source, contains('finally { state.leave(value); }'));
    },
  );

  test(
    'nested Dictionary generation imports its canonical public API',
    () async {
      final dart = emitNativeDart(
        await read('''
import 'package:napi/napi.dart' as api;
typedef Alias<T> = api.Dictionary<T>;
@api.NAPI() List<Alias<int?>?> nested(List<Alias<int?>?> value) => value;
'''),
      );
      expect(dart, contains("import 'package:napi/napi.dart' as napi;"));
      expect(dart, contains("import 'dart:convert' show jsonEncode;"));
      expect(dart, contains('napi.Dictionary<int?>'));
      expect(dart, isNot(contains('target.Dictionary')));
      expect(dart, contains('_api.rollbackReferences(state.pending)'));
      final scalar = emitNativeDart(
        await read(
          "import 'package:napi/napi.dart'; @NAPI() int f(int x) => x;",
        ),
      );
      expect(
        scalar,
        isNot(contains("import 'package:napi/napi.dart' as napi;")),
      );
      expect(scalar, isNot(contains("import 'dart:convert' show jsonEncode;")));
    },
  );

  test(
    'Dictionary class calls preserve presence, brands and void results',
    () async {
      final plan = await read();
      final dart = emitNativeDart(plan);
      expect(dart, contains('_api.ownerValue(env, value, path, 0)'));
      expect(
        dart,
        contains('_api.referenceResult(env, value!, 0, path, state.pending)'),
      );
      final direct = _callback(dart, plan.functions.first);
      expect(direct, contains('call.argumentCount > 0 ? call.arguments[0]'));
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
      expect(mirror, isNot(contains('call.argumentCount >')));
      expect(
        mirror.indexOf('ownerValue('),
        lessThan(mirror.indexOf('requiredArgument(')),
      );
      final from = _callback(
        dart,
        group.members.singleWhere((call) => call.exportName == 'from'),
      );
      expect(from, contains('_api.defaultOption(call.env, options, 0)'));
      final maybe = _callback(
        dart,
        group.members.singleWhere((call) => call.exportName == 'maybe'),
      );
      expect(maybe, contains('_api.omittedOrUndefined(call, 0)'));
      expect(maybe, contains('a0 = null;'));
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
    'Dictionary functions and class members compile as actual native AOT',
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

  test('native Dictionary declarations compile for a TypeScript consumer', () async {
    final types = emitNativeDeclarations(await read());
    expect(types, contains('{ [key: string]: number | null }'));
    expect(
      types,
      contains('constructor(members: { [key: string]: Box | null });'),
    );
    expect(types, contains('globalThis.Map<string, number>'));
    expect(types, contains('wide: bigint'));
    expect(types, contains('user: (value: UserDictionary) => UserDictionary'));
    await File('${directory.path}/module.d.mts').writeAsString(types);
    final consumer = File('${directory.path}/consumer.mts');
    await consumer.writeAsString('''
import {Box, Group, UserDictionary, direct, nested, wide, optional, requiredNamed, mixed, user} from './module.mjs';
const box = new Box(1);
const members = {box, none: null};
const group = new Group(members);
direct({a: 1, b: null, ['__proto__']: 2});
nested([{value: {members, maps: new Map([['list', [1, null]]])}}, null]);
nested(null);
wide({value: {wide: 42n, huge: 1n << 200n}});
optional(); optional(undefined); optional(null);
requiredNamed({value: {a: 1}});
mixed(new Map([['a', 1]]), {a: 1});
group.members = members; group.mirror({list: [box, null]});
group.maybe(); group.maybe(undefined); group.maybe(null);
group.select({value: members}); group.take(members); Group.echo(members);
const from: Group = Group.from({members: undefined});
user(new UserDictionary(1));
// @ts-expect-error Dictionary values retain strict scalar types.
direct({a: true});
// @ts-expect-error Dictionary values retain the selected bigint policy.
wide({value: {wide: 42, huge: 1n}});
// @ts-expect-error The same signature distinguishes a Map from a Dictionary.
mixed({a: 1}, new Map([['a', 1]]));
// @ts-expect-error Selected reference Dictionary keeps its declared member types.
user({id: 'invalid'});
// @ts-expect-error A required named Dictionary argument remains required.
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
