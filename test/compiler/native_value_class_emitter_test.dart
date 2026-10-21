import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/loader.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;
const _source = '''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.value)
class Point {
  Point(this.x, {this.y = 2});
  final int x;
  final int y;
  int get total => x + y;
}
@NAPI() class Ref { Ref(this.value); int value; }
@NAPI(classPolicy: ClassPolicy.value)
class Node {
  Node(this.children, {this.next, this.ref});
  final List<Node> children;
  final Node? next;
  final Ref? ref;
}
@NAPI(classPolicy: ClassPolicy.value)
class Left { Left(this.right); final Right? right; }
@NAPI(classPolicy: ClassPolicy.value)
class Right { Right(this.left); final Left? left; }
@NAPI(classPolicy: ClassPolicy.value, valueFields: {'source': 'value'})
abstract class Normalized {
  factory Normalized.from(String source, {int code = 3}) => _Normalized(source, code: code);
  int get value;
  int get code;
}
class _Normalized implements Normalized {
  _Normalized(String source, {this.code = 3}) : value = int.parse(source);
  @override final int value;
  @override final int code;
}
@NAPI() class Holder {
  Holder(this.point);
  Point point;
  List<Point> echo(List<Point> values) => values;
  int needsScalar(Point first, int second) => first.x + second;
}
@NAPI() int needsRef(Point first, Ref second) => first.x + second.value;
@NAPI() int optionalRef(Point first, [Ref? second]) => first.x;
@NAPI() int namedScalar(Point first, {required int second}) => first.x + second;
@NAPI() int directScalar(Point first, int second) => first.x + second;
@NAPI() Node echoNode(Node value) => value;
@NAPI() Left? echoMutual(Left? value) => value;
@NAPI() Map<Node, (Point, Ref?)> echoMap(Map<Node, (Point, Ref?)> value) => value;
@NAPI() Dictionary<Point> echoDictionary(Dictionary<Point> value) => value;
@NAPI() Normalized normalize(Normalized value) => value;
@NAPI(bigint: true) Point wide(Point value) => value;
''';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'napi-native-value-emitter-',
    );
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<NativeModulePlan> read(String text) async {
    final source = File('${directory.path}/business.dart');
    await source.writeAsString(text);
    return validateNative(
      await AnnotationFrontend(
        packagesPath: _packages,
        native: true,
      ).read(source.uri),
    );
  }

  Future<void> compile(String source) async {
    final entry = File('${directory.path}/entry.dart');
    await entry.writeAsString(source);
    final result = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'aot-snapshot',
      '--packages=$_packages',
      entry.path,
      '--output=${directory.path}/module.aot',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }

  test('recursive value graphs generate typed two-phase AOT without reference ID gaps', () async {
    final plan = await read(_source);
    expect(plan.valueSchemas, hasLength(5));
    expect(plan.classes.map((c) => c.binding.exportName), ['Ref', 'Holder']);
    expect(plan.classes.map((c) => c.constructor.classId), [0, 1]);
    final nodeCall = plan.functions.singleWhere(
      (f) => f.exportName == 'echoNode',
    );
    final node = nodeCall.inputs.single as ValueClassConversion;
    final refs = conversionGraph([node]).whereType<ReferenceConversion>();
    expect(refs.map((ref) => ref.classId).toSet(), {0});
    expect(node.direction, ValueDirection.input);
    expect(
      (nodeCall.output as ValueClassConversion).direction,
      ValueDirection.output,
    );
    final code = emitNativeDart(plan);
    expect(code, contains('_normalizeNativeStructure'));
    expect(code, contains('_materializeNativeStructure'));
    expect(code, contains('final normalized ='));
    expect(code, contains('readOptionalOwnValue'));
    expect(code, contains('target.Normalized.from('));
    expect(code, contains('target.Left('));
    expect(code, contains('target.Right('));
    expect(code, contains('final raw0 = value.x;'));
    expect(code, contains('final raw1 = value.y;'));
    expect(code, contains('final raw2 = value.total;'));
    expect(code, contains('_api.integerBigInt('));
    expect(code, contains('_api.rollbackReferences(state.pending)'));
    await compile(code);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('value callables finish presence and direct-ref checks before constructing parameters', () async {
    final plan = await read(_source);
    final code = emitNativeDart(plan);
    String body(NativeCallPlan call) {
      final start = code.indexOf('int ${call.callback}(');
      final end = code.indexOf('\nint _native', start + 1);
      return code.substring(start, end < 0 ? code.length : end);
    }

    NativeCallPlan function(String name) =>
        plan.functions.singleWhere((f) => f.exportName == name);
    final required = body(function('needsRef'));
    final readIndex = required.indexOf('_NativeReadState()');
    expect(
      required.indexOf('final raw1 = _api.requiredArgument'),
      inInclusiveRange(0, readIndex - 1),
    );
    expect(
      required.indexOf('_api.ownerValue(call.env, raw1'),
      inInclusiveRange(0, readIndex - 1),
    );
    final optional = body(function('optionalRef'));
    expect(
      optional.indexOf('final default1 ='),
      lessThan(optional.indexOf('_NativeReadState()')),
    );
    expect(optional, contains('if (default1)'));
    final named = body(function('namedScalar'));
    expect(
      named.indexOf('_api.requiredOption'),
      lessThan(named.indexOf('_NativeReadState()')),
    );
    final member = body(
      plan.classes.last.members.singleWhere(
        (m) => m.exportName == 'needsScalar',
      ),
    );
    expect(
      member.indexOf('final raw1 = _api.requiredArgument'),
      lessThan(member.indexOf('_NativeReadState()')),
    );
    // Required direct Wasm functions have no JS presence prepass. Preserve
    // their per-parameter construction instead of validating the whole call.
    final direct = body(function('directScalar'));
    expect(
      direct.indexOf('_api.requiredArgument(call, 1'),
      greaterThan(direct.indexOf('_NativeReadState()')),
    );
  });

  test(
    'value constructor resource defaults are retained during normalization',
    () async {
      final plan = await read('''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  const Resource(this.id);
  final int id;
  void close() {}
}
@NAPI(classPolicy: ClassPolicy.value)
class Defaults {
  Defaults({
    this.resource = const Resource(1),
    this.values = const [Resource(2), null],
    this.mapping = const {Resource(3): Resource(4)},
    this.dictionary = const Dictionary({'value': Resource(5)}),
    this.record = const (Resource(6), [Resource(7)]),
    this.tail = 0,
  });
  final Resource resource;
  final List<Resource?> values;
  final Map<Resource, Resource> mapping;
  final Dictionary<Resource> dictionary;
  final (Resource, List<Resource>) record;
  final int tail;
}
@NAPI() Defaults echo(Defaults value) => value;
@NAPI() Future<Resource> later(Defaults value) async => value.resource;
@NAPI() Resource lazy(JsArray<Defaults> values) => values.get(0)!.resource;
''');
      final code = emitNativeDart(plan);
      final first = code.indexOf('readOptionalOwnValue(env, value, "resource"');
      expect(first, greaterThanOrEqualTo(0));
      final normalize = code.substring(first, code.indexOf('\n}', first));
      final retain = normalize.indexOf('state.retain(_resourceControl(');
      expect(retain, greaterThan(normalize.indexOf('if (default0)')));
      expect(retain, lessThan(normalize.indexOf('"values"')));
      expect(normalize, contains('"tail"'));
      expect(normalize, isNot(contains('target.Defaults(')));
      expect(code, contains('_api.attachOperation(token, operation)'));
      await compile(code);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'pure structural inputs retain the original direct typed traversal',
    () async {
      final plan = await read(
        "import 'package:napi/napi.dart'; @NAPI() List<int> echo(List<int> value) => value;",
      );
      final code = emitNativeDart(plan);
      expect(code, isNot(contains('_normalizeNativeStructure')));
      expect(code, contains('final result = <int>[];'));
    },
  );

  test('output-only nesting fails before native emission', () async {
    await expectLater(
      read('''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.value) class Output { Output._(); final int value = 1; }
@NAPI() List<Output> invalid(List<Output> values) => values;
'''),
      throwsA(
        isA<BindingDiagnostic>().having(
          (e) => e.code,
          'code',
          'NAPI_VALUE_INPUT',
        ),
      ),
    );
  });

  test('a type-only value module emits no runtime class export', () async {
    final plan = await read('''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.value) class Output { final int value = 1; }
''');
    expect(plan.classes, isEmpty);
    expect(plan.functions, isEmpty);
    expect(plan.valueSchemas, hasLength(1));
    final types = emitNativeDeclarations(plan);
    expect(types, contains('export type Output ='));
    expect(types, isNot(contains('declare class Output')));
    expect(
      emitNativeLoader([], classes: plan.classes),
      isNot(contains(' as Output')),
    );
    await compile(emitNativeDart(plan));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
