import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/js/boundary.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/loader.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-js-collections-');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<BindingModule> read(String source) async {
    final file = await File('${directory.path}/entry.dart').writeAsString('''
import 'package:napi/napi.dart';
$source
''');
    return AnnotationFrontend(packagesPath: packages).read(file.uri);
  }

  test('value element policies carry finite input and output graphs', () async {
    final module = await read('''
@NAPI(classPolicy: ClassPolicy.value)
class Node { Node(this.id, {this.children}); final int id; final JsArray<Node>? children; }
@NAPI(classPolicy: ClassPolicy.value)
class Parsed { Parsed.parse(String source) : value = int.parse(source); final int value; }
@NAPI(classPolicy: ClassPolicy.value)
class Only { Only._(this.value); final int value; }
@NAPI() JsArray<Node> nodes(JsArray<Node> source) => source;
@NAPI() JsArray<List<Parsed>> values(JsArray<List<Parsed>> source) => source;
@NAPI() JsMap<Parsed, Only?> keys(JsMap<Parsed, Only?> source) => source;
@NAPI(bigint: true) JsArray<Node> wide(JsArray<Node> source) => source;
''');
    final wasm = lower(validate(module));
    final native = validateNative(module);
    for (final roots in [
      wasm.functions.map((f) => f.inputs.single),
      native.functions.map((f) => f.inputs.single),
    ]) {
      final node = roots.first as JsCollectionConversion;
      final output = node.value as ValueClassConversion;
      final input = node.inputValue as ValueClassConversion;
      expect(output.direction, ValueDirection.output);
      expect(input.direction, ValueDirection.input);
      expect(input.schemaId, output.schemaId);
      final inner = output.fields.last.conversion as JsCollectionConversion;
      expect(inner.value, same(output));
      expect(inner.inputValue, same(input));
      expect(node.signatureKey, contains('value'));
      expect(node.signatureKey.length, lessThan(100));
      expect(
        node.signatureKey,
        isNot((roots.last as JsCollectionConversion).signatureKey),
      );
      expect(conversionGraph([node]), hasLength(1));
      expect(
        conversionDependencies([node]).whereType<ValueClassConversion>(),
        hasLength(2),
      );
      final map = roots.elementAt(2) as JsCollectionConversion;
      expect(map.inputValue.typescriptType, 'null');
      expect(
        (map.inputKey as ValueClassConversion).fields.single.name,
        'source',
      );
      expect((map.key as ValueClassConversion).fields.single.name, 'value');
    }
    final types = emitDeclarations(wasm);
    expect(types, emitNativeDeclarations(native));
    expect(types, contains('"source": string'));
    expect(types, contains('"value": number'));
    expect(types, contains(' | '));
  });

  test('lazy output-only nodes do not grant ordinary value inputs', () async {
    for (final type in [
      '(JsArray<Only>, Only)',
      'List<Only>',
      '(JsArray<Only>, List<Only>)',
    ]) {
      final module = await read('''
@NAPI(classPolicy: ClassPolicy.value) class Only { Only._(); int get value => 1; }
@NAPI() void bad($type value) {}
''');
      for (final check in [validate, validateNative]) {
        expect(() => check(module), throwsA(isA<BindingDiagnostic>()));
      }
    }
  });

  test(
    'value handles build with recursive, asymmetric and output-only elements',
    () async {
      final input = await File('${directory.path}/values.dart')
          .writeAsString('''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.value)
class Node { Node(this.id, {this.children}); final int id; final JsArray<Node>? children; }
@NAPI(classPolicy: ClassPolicy.value)
class Parsed { Parsed.parse(String source) : value = int.parse(source); final int value; }
@NAPI(classPolicy: ClassPolicy.value)
class Only { Only._(this.value); final int value; }
class Box<T> { Box(this.value); final T value; }
@NAPI(classPolicy: ClassPolicy.value) typedef IntBox = Box<int>;
@NAPI(classPolicy: ClassPolicy.value) class Seed { const Seed(this.n); final int n; }
@NAPI(classPolicy: ClassPolicy.value) class Defaulted { Defaulted({this.seed = const Seed(3)}); final Seed seed; }
@NAPI(classPolicy: ClassPolicy.value)
class Ordered {
  final _values = [1];
  Ordered._();
  List<int> get values => _values;
  int get tail { _values[0] = 2; return 2; }
}
@NAPI() JsArray<Ordered> order(JsArray<Ordered> source) { source.set(0, Ordered._()); return source; }
@NAPI() Ordered ordinary() => Ordered._();
@NAPI() JsArray<IntBox> boxes(JsArray<IntBox> source) { source.set(1, source.get(0)!); return source; }
@NAPI() JsArray<Defaulted> defaults(JsArray<Defaulted> source) { source.set(1, source.get(0)!); return source; }
@NAPI() JsArray<Node> nodes(JsArray<Node> source) { source.set(1, source.get(0)!); return source; }
@NAPI() int deep(JsArray<Node> source) => source.get(0)!.children!.get(0)!.id;
@NAPI() JsArray<Parsed> parsed(JsArray<Parsed> source) { source.set(1, source.get(0)!); return source; }
@NAPI() int readParsed(JsArray<Parsed> source) => source.get(1)!.value;
@NAPI() JsArray<Only?> writeOnly(JsArray<Only?> source) { source.set(0, Only._(9)); return source; }
@NAPI() int readOnly(JsArray<Only?> source) => source.get(0)?.value ?? -1;
@NAPI() JsArray<(Node, JsArray<T>)> pair<T>(JsArray<(Node, JsArray<T>)> source) { source.set(1, source.get(0)!); return source; }
''');
      await buildLibrary(
        library: input.uri,
        output: Directory('${directory.path}/values'),
        packagesPath: packages,
      );
      await File('${directory.path}/values.mjs').writeAsString('''
import assert from 'node:assert/strict';
import * as api from './values/module.wasm';
const child = [{id: 7}], source = [{id: 1, children: child}];
assert.equal(api.nodes(source), source); assert.notEqual(source[1], source[0]);
assert.equal(source[1].children, child); assert.equal(api.deep(source), 7);
assert.throws(() => api.nodes([{id: 'bad'}]), TypeError);
const parsed = [{source: '19'}]; assert.equal(api.parsed(parsed), parsed);
assert.deepEqual(parsed[1], {value: 19}); assert.throws(() => api.readParsed(parsed), TypeError);
const only = []; assert.equal(api.writeOnly(only), only); assert.deepEqual(only[0], {value: 9});
assert.throws(() => api.readOnly(only), TypeError);
assert.equal(api.readOnly([]), -1); assert.equal(api.readOnly([null]), -1);
const boxes = [{value: 5}]; assert.equal(api.boxes(boxes), boxes); assert.deepEqual(boxes[1], {value: 5});
assert.notEqual(boxes[1], boxes[0]); assert.throws(() => api.boxes([{value: 'bad'}]), TypeError);
const defaults = [{}]; assert.equal(api.defaults(defaults), defaults); assert.deepEqual(defaults[1], {seed: {n: 3}});
const ordered = []; assert.equal(api.order(ordered), ordered); assert.deepEqual(ordered[0], {values: [1], tail: 2});
assert.deepEqual(api.ordinary(), {values: [2], tail: 2});
const opaque = [undefined, null, Symbol('value')], pair = [{\$1: {id: 2}, \$2: opaque}];
assert.equal(api.pair(pair), pair); assert.notEqual(pair[1], pair[0]);
assert.equal(pair[1].\$1.id, 2); assert.equal(pair[1].\$2, opaque);
''');
      final result = await Process.run('node', [
        'values.mjs',
      ], workingDirectory: directory.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('canonical handles retain scalar policy and native TS shape', () async {
    final module = await read('''
typedef Numbers = JsArray<int>;
@NAPI() Numbers array(Numbers value) => value;
@NAPI() JsMap<String?, double?> map(JsMap<String?, double?> value) => value;
@NAPI() Future<JsArray<int>> later(JsArray<int> value) async => value;
@NAPI() Stream<JsMap<String, int?>> events(JsMap<String, int?> value) => Stream.value(value);
@NAPI() JsArray<int>? nullable([JsArray<int>? value]) => value;
@NAPI() JsArray<bool> boolean(JsArray<bool> value) => value;
@NAPI(bigint: true) JsArray<bool> sameBoolean(JsArray<bool> value) => value;
@NAPI(bigint: true) JsArray<int> big(JsArray<int> value) => value;
''');
    final wasm = lower(validate(module));
    final native = validateNative(module);
    for (final conversions in [
      wasm.functions.map((f) => f.inputs.single),
      native.functions.map((f) => f.inputs.single),
    ]) {
      final values = conversions.cast<JsCollectionConversion>().toList();
      expect(values[0].dartType, 'napi.JsArray<int>');
      expect(
        values[1].typescriptType,
        'globalThis.Map<string | null, number | null>',
      );
      expect(values[0].signatureKey, values[4].signatureKey);
      expect(values[5].signatureKey, values[6].signatureKey);
      expect(values[0].signatureKey, isNot(values[7].signatureKey));
    }
    for (final text in [
      emitDeclarations(wasm),
      emitNativeDeclarations(native),
    ]) {
      expect(text, contains('globalThis.Array<number>'));
      expect(text, contains('globalThis.Array<bigint>'));
      expect(text, isNot(contains('LiveList')));
      expect(text, isNot(contains('unique symbol')));
    }
  });

  test('copied containers discover terminal handle policies without changing root contexts', () async {
    final module = await read('''
@NAPI() List<JsArray<int>> arrays(List<JsArray<int>> value) => value;
@NAPI() Map<String, JsMap<String, int?>> maps(Map<String, JsMap<String, int?>> value) => value;
@NAPI() Dictionary<JsArray<int>?> dictionary(Dictionary<JsArray<int>?> value) => value;
@NAPI() (JsArray<T>, JsMap<String, T?>) record<T>((JsArray<T>, JsMap<String, T?>) value) => value;
@NAPI(classPolicy: ClassPolicy.value)
class Packet { Packet(this.items); final JsArray<int> items; }
@NAPI() Packet packet(Packet value) => value;
''');
    final wasm = lower(validate(module));
    final native = validateNative(module);
    expect(wasm.conversions.whereType<JsCollectionConversion>(), isEmpty);
    expect(
      conversionGraph(wasm.conversions).whereType<JsCollectionConversion>(),
      isNotEmpty,
    );
    final scalarOnly = lower(
      validate(
        BindingModule(
          source: module.source,
          functions: [module.functions.first],
        ),
      ),
    );
    expect(emitDart(scalarOnly), contains('final class _NapiHostValue'));
    final dart = emitDart(wasm);
    final boundary = emitBoundary(wasm);
    expect(dart, contains('final class _NapiHostValue'));
    expect(dart, contains('_jcAdapter<'));
    expect(dart, isNot(contains('external WasmExternRef _boxOpaque')));
    expect(boundary, contains(r'const $jcPolicies ='));
    expect(boundary, contains(r'$jcAdmit(value,'));
    expect(boundary, contains('if (value === false)'));
    expect(boundary, isNot(contains('function boxOpaque')));
    for (final (index, conversion) in wasm.conversions.indexed) {
      expect(boundary, contains('case $index:'));
      expect(conversion, isNot(isA<JsCollectionConversion>()));
    }
    expect(emitDeclarations(wasm), emitNativeDeclarations(native));
    expect(emitDeclarations(wasm), contains('globalThis.Array<T>'));
    expect(native.jsCollections, isNotEmpty);
    expect(emitNativeDart(native), contains('jsCollectionResult'));
  });

  test(
    'resource collections scope later calls without changing unrelated modules',
    () async {
      for (final element in [
        'Resource',
        'Resource?',
        'JsArray<Resource>',
        'List<Resource>',
        'Dictionary<({Resource value})>',
        'Map<Resource, List<Resource?>>',
        'List<JsArray<List<Resource>>>',
      ]) {
        final module = await read('''
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource { Resource(); void close() {} }
@NAPI() JsArray<$element> keep(JsArray<$element> value) => value;
@NAPI() int later() => 1;
''');
        final wasm = lower(validate(module));
        final native = validateNative(module);
        expect(wasm.hasResourceCollections, isTrue);
        expect(wasm.needsResourceOperation(wasm.functions.last), isTrue);
        expect(
          wasm.functions.last.representation,
          ExportRepresentation.callableGlobal,
        );
        expect(emitDeclarations(wasm), emitNativeDeclarations(native));
      }
      final module = await read('''
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource { Resource(); void close() {} }
@NAPI() JsArray<int> keep(JsArray<int> value) => value;
@NAPI() int later() => 1;
''');
      final wasm = lower(validate(module));
      expect(wasm.hasResourceCollections, isFalse);
      expect(wasm.needsResourceOperation(wasm.functions.last), isFalse);
      expect(
        wasm.functions.last.representation,
        ExportRepresentation.nativeFunction,
      );
      expect(
        emitNativeDart(validateNative(module)),
        isNot(contains('_retainJsCollectionResource')),
      );
    },
  );

  test('unused modules emit no collection runtime', () async {
    final module = await read('@NAPI() int add(int a, int b) => a + b;');
    final wasm = lower(validate(module));
    expect(emitDart(wasm), isNot(contains('_jc')));
    expect(emitBoundary(wasm), isNot(contains(r'$jc')));
    expect(emitNativeLoader(['add']), isNot(contains(r'$jc')));
  });

  test('copied element policies retain their full mutable shape', () async {
    final module = await read('''
import 'dart:typed_data';
@NAPI() JsArray<List<int>> lists(JsArray<List<int>> value) => value;
@NAPI() JsArray<List<int>?> nullableList(JsArray<List<int>?> value) => value;
@NAPI() JsArray<List<int?>> nullableLeaf(JsArray<List<int?>> value) => value;
@NAPI(bigint: true) JsArray<List<int>> wide(JsArray<List<int>> value) => value;
@NAPI() JsArray<List<double>> floating(JsArray<List<double>> value) => value;
@NAPI() JsArray<Map<String, List<int>>> maps(JsArray<Map<String, List<int>>> value) => value;
@NAPI() JsArray<Dictionary<List<int>>> dictionaries(JsArray<Dictionary<List<int>>> value) => value;
@NAPI() JsArray<(int, {List<String?> values})> records(JsArray<(int, {List<String?> values})> value) => value;
@NAPI() JsArray<(int, {List<String?> other})> otherField(JsArray<(int, {List<String?> other})> value) => value;
@NAPI() JsArray<({int a, String b})> named(JsArray<({int a, String b})> value) => value;
@NAPI() JsArray<({String b, int a})> reordered(JsArray<({String b, int a})> value) => value;
@NAPI() JsMap<List<int>, Dictionary<(bool, Uint8List?)>> mixed(JsMap<List<int>, Dictionary<(bool, Uint8List?)>> value) => value;
@NAPI() JsArray<List<ByteBuffer>> buffers(JsArray<List<ByteBuffer>> value) => value;
@NAPI() JsArray<List<SharedBytes>> shared(JsArray<List<SharedBytes>> value) => value;
@NAPI() JsArray<List<Uint8List>> bytes(JsArray<List<Uint8List>> value) => value;
@NAPI() JsArray<()> empty(JsArray<()> value) => value;
''');
    final wasm = lower(validate(module));
    final native = validateNative(module);
    for (final (inputs, outputs) in [
      (
        wasm.functions.map((f) => f.inputs.single).toList(),
        wasm.functions.map((f) => f.output).toList(),
      ),
      (
        native.functions.map((f) => f.inputs.single).toList(),
        native.functions.map((f) => f.output).toList(),
      ),
    ]) {
      final values = inputs.cast<JsCollectionConversion>();
      for (final (index, input) in values.indexed) {
        final output = outputs[index] as JsCollectionConversion;
        expect(input.signatureKey, output.signatureKey);
        expect(input.typescriptType, output.typescriptType);
        expect(input.typescriptType, isNot(contains('ReadonlyArray')));
      }
      expect({
        for (final i in [0, 1, 2, 3, 4]) values[i].signatureKey,
      }, hasLength(5));
      expect(values[5].signatureKey, isNot(values[6].signatureKey));
      expect(values[7].signatureKey, isNot(values[8].signatureKey));
      expect(values[9].signatureKey, values[10].signatureKey);
      expect(
        (values[9].value as RecordConversion).named.keys,
        (values[10].value as RecordConversion).named.keys,
      );
      expect({
        for (final i in [12, 13, 14]) values[i].signatureKey,
      }, hasLength(3));
      expect(values[0].value, isA<ListConversion>());
      expect(values[5].value, isA<MapConversion>());
      expect(values[6].value, isA<DictionaryConversion>());
      expect(values[7].value, isA<RecordConversion>());
      expect(values[11].key, isA<ListConversion>());
    }
    final dependencies = conversionDependencies(wasm.conversions).toList();
    expect(
      dependencies.whereType<BinaryConversion>().map((c) => c.kind).toSet(),
      {BinaryKind.uint8List, BinaryKind.byteBuffer},
    );
    expect(dependencies.whereType<SharedBytesConversion>(), isNotEmpty);
    expect(dependencies.whereType<MapConversion>(), isNotEmpty);
    expect(dependencies.whereType<DictionaryConversion>(), isNotEmpty);
    expect(dependencies.whereType<RecordConversion>(), isNotEmpty);
    expect(
      conversionGraph(wasm.conversions).whereType<ListConversion>(),
      isEmpty,
    );
    expect(native.hasBinary, isTrue);
    expect(native.hasSharedBytesTypes, isTrue);
    expect(emitDeclarations(wasm), emitNativeDeclarations(native));
    expect(emitDeclarations(wasm), contains('globalThis.Array<Array<number>>'));
  });

  test(
    'copied element leaves preserve reference, opaque and handle policies',
    () async {
      final module = await read('''
@NAPI() class Ref<T> { Ref(this.value); final T value; }
@NAPI() class Other { Other(); }
@NAPI() JsArray<List<T>> opaque<T>(JsArray<List<T>> value) => value;
@NAPI() JsArray<List<U>> renamed<U>(JsArray<List<U>> value) => value;
@NAPI() JsArray<List<T?>> nullable<T>(JsArray<List<T?>> value) => value;
@NAPI() JsArray<List<Ref<T>>> references<T>(JsArray<List<Ref<T>>> value) => value;
@NAPI() JsArray<List<Ref<T>?>> nullableReferences<T>(JsArray<List<Ref<T>?>> value) => value;
@NAPI() JsArray<List<Other>> other(JsArray<List<Other>> value) => value;
@NAPI() JsArray<Map<Ref<T>, Dictionary<({T payload, JsArray<T?> nested})>>> mixed<T>(JsArray<Map<Ref<T>, Dictionary<({T payload, JsArray<T?> nested})>>> value) => value;
@NAPI() JsMap<List<T>, List<JsMap<String, T>>> keys<T>(JsMap<List<T>, List<JsMap<String, T>>> value) => value;
@NAPI() Future<JsArray<List<T>>> callback<T>(Future<JsArray<List<T>>> Function(JsArray<List<T>>) f, JsArray<List<T>> value) => f(value);
''');
      final wasm = lower(validate(module));
      final native = validateNative(module);
      for (final conversions in [
        wasm.functions.take(8).map((f) => f.inputs.single),
        native.functions.take(8).map((f) => f.inputs.single),
      ]) {
        final values = conversions.cast<JsCollectionConversion>().toList();
        expect(values[0].signatureKey, values[1].signatureKey);
        expect(values[0].signatureKey, isNot(values[2].signatureKey));
        expect(values[3].signatureKey, isNot(values[4].signatureKey));
        expect(values[3].signatureKey, isNot(values[5].signatureKey));
        expect(
          (values[0].value as ListConversion).element,
          isA<OpaqueConversion>(),
        );
        expect(
          (values[3].value as ListConversion).element,
          isA<ReferenceConversion>(),
        );
        expect(containsJsCollectionReference(values[6]), isTrue);
        expect(containsJsCollectionReference(values[7]), isFalse);
      }
      final handleInputs = wasm.functions.take(8).map((f) => f.inputs.single);
      final dependencies = conversionDependencies(handleInputs).toList();
      expect(dependencies.whereType<OpaqueConversion>(), isNotEmpty);
      expect(dependencies.whereType<ReferenceConversion>(), isNotEmpty);
      expect(
        dependencies.whereType<JsCollectionConversion>(),
        hasLength(greaterThan(8)),
      );
      expect(
        conversionGraph(handleInputs).whereType<OpaqueConversion>(),
        isEmpty,
      );
      expect(
        conversionGraph(handleInputs).whereType<ReferenceConversion>(),
        isEmpty,
      );
      expect(emitDeclarations(wasm), emitNativeDeclarations(native));
      expect(emitDeclarations(wasm), contains('globalThis.Array<Array<T>>'));
      expect(emitDeclarations(wasm), isNot(contains('ReadonlyArray')));
    },
  );

  test(
    'pure copied reference and opaque leaves build without eager admission',
    () async {
      final input = await File('${directory.path}/copied_leaves.dart')
          .writeAsString('''
import 'package:napi/napi.dart';
@NAPI() class Item { Item(this.id); final int id; }
@NAPI() JsArray<List<T>> opaque<T>(JsArray<List<T>> source) {
  source.set(1, source.get(0)!);
  return source;
}
@NAPI() JsArray<List<T?>> nullable<T>(JsArray<List<T?>> source) {
  source.set(1, source.get(0)!);
  return source;
}
@NAPI() JsArray<({T value})> record<T>(JsArray<({T value})> source) {
  source.set(1, source.get(0)!);
  return source;
}
@NAPI() JsArray<List<Item?>> references(JsArray<List<Item?>> source) {
  source.set(1, source.get(0)!);
  return source;
}
@NAPI() JsArray<List<JsMap<String, JsArray<int>>>> handles(JsArray<List<JsMap<String, JsArray<int>>>> source) {
  final value = source.get(0)!;
  value.single.get('items')!.set(0, 9);
  source.set(1, value);
  return source;
}
@NAPI() JsArray<Map<Item, Dictionary<T>>> maps<T>(JsArray<Map<Item, Dictionary<T>>> source) {
  source.set(1, source.get(0)!);
  return source;
}
@NAPI() JsArray<List<T>> unread<T>(JsArray<List<T>> source) => source;
''');
      await buildLibrary(
        library: input.uri,
        output: Directory('${directory.path}/copied_leaves'),
        packagesPath: packages,
      );
      await File('${directory.path}/copied_leaves.mjs').writeAsString('''
import assert from 'node:assert/strict';
import * as api from './copied_leaves/module.wasm';
const object = {};
for (const value of [null, undefined, object, Symbol('opaque'), 1n]) {
  const source = [[value]];
  assert.equal(api.opaque(source), source);
  assert.notEqual(source[1], source[0]); assert.equal(source[1][0], value);
  const record = [{value}];
  assert.equal(api.record(record), record);
  assert.notEqual(record[1], record[0]); assert.equal(record[1].value, value);
}
const nullable = [[null, undefined, object]];
assert.equal(api.nullable(nullable), nullable);
assert.deepEqual(nullable[1], nullable[0]); assert.notEqual(nullable[1], nullable[0]);
const item = new api.Item(3), references = [[item, null]];
assert.equal(api.references(references), references);
assert.notEqual(references[1], references[0]); assert.equal(references[1][0], item);
assert.equal(references[1][1], null);
assert.throws(() => api.references([[{}]]), TypeError);
const inner = [1], map = new Map([['items', inner]]), handles = [[map]];
assert.equal(api.handles(handles), handles); assert.equal(inner[0], 9);
assert.notEqual(handles[1], handles[0]); assert.equal(handles[1][0], map);
assert.equal(handles[1][0].get('items'), inner);
const dictionary = {payload: object}, maps = [new Map([[item, dictionary]])];
assert.equal(api.maps(maps), maps); assert.notEqual(maps[1], maps[0]);
assert.equal([...maps[1].keys()][0], item);
assert.notEqual(maps[1].get(item), dictionary);
assert.equal(maps[1].get(item).payload, object);
const invalid = [{}]; assert.equal(api.unread(invalid), invalid);
''');
      final result = await Process.run('node', [
        'copied_leaves.mjs',
      ], workingDirectory: directory.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'pure copied handle elements build and preserve snapshot behavior',
    () async {
      final input = await File('${directory.path}/copied.dart')
          .writeAsString('''
import 'package:napi/napi.dart';
@NAPI() JsArray<List<int>?> lists(JsArray<List<int>?> source) {
  final value = source.get(0);
  if (value != null) value[0] += 10;
  source.set(1, value);
  return source;
}
@NAPI() JsArray<Map<String, List<int>>> maps(JsArray<Map<String, List<int>>> source) {
  final value = source.get(0)!;
  value['key']![0] += 10;
  source.set(1, value);
  return source;
}
@NAPI() JsArray<Dictionary<(int, String?)>> dictionaries(JsArray<Dictionary<(int, String?)>> source) {
  final value = source.get(0)!;
  value['key'] = (value['key']!.\$1 + 10, null);
  source.set(1, value);
  return source;
}
@NAPI() JsArray<(int, {List<bool> flags, String \$cost})> records(JsArray<(int, {List<bool> flags, String \$cost})> source) {
  final value = source.get(0)!;
  value.flags[0] = !value.flags[0];
  source.set(1, (value.\$1 + 10, flags: value.flags, \$cost: value.\$cost + '!'));
  return source;
}
@NAPI() JsMap<List<int>, List<int>> keys(JsMap<List<int>, List<int>> source) {
  final (key, value) = source.entries.first;
  if (source.has(key)) throw StateError('copied keys must be independent');
  key[0] += 10;
  source.set(key, value);
  return source;
}
@NAPI(bigint: true) JsArray<List<int>> wide(JsArray<List<int>> source) {
  source.set(1, source.get(0)!);
  return source;
}
@NAPI() JsArray<({int id, String tag})> named(JsArray<({int id, String tag})> source) {
  final value = source.get(0)!;
  source.set(1, (id: value.id + 1, tag: value.tag + 'a'));
  return source;
}
@NAPI() JsArray<({String tag, int id})> reordered(JsArray<({String tag, int id})> source) {
  final value = source.get(0)!;
  source.set(2, (tag: value.tag + 'b', id: value.id + 2));
  return source;
}
@NAPI() Future<JsArray<List<int>?>> callback(Future<JsArray<List<int>?>> Function(JsArray<List<int>?>) f, JsArray<List<int>?> source) async => lists(await f(source));
int _cleanups = 0;
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  Resource(this.id);
  final int id;
  void close() { _cleanups++; }
}
@NAPI() int cleanups() => _cleanups;
@NAPI() Future<int> mixed(JsMap<Resource, List<int>> source, Future<void> Function() wait) async {
  final (key, value) = source.entries.first;
  await wait();
  return key.id + value.single;
}
''');
      await buildLibrary(
        library: input.uri,
        output: Directory('${directory.path}/copied'),
        packagesPath: packages,
      );
      await File('${directory.path}/copied.mjs').writeAsString('''
import assert from 'node:assert/strict';
const original = ['read', 'write'].map(name => [name, Object.getOwnPropertyDescriptor(Object.prototype, name)]);
let registrations = 0, api;
try {
  for (const [name] of original) Object.defineProperty(Object.prototype, name, {
    configurable: true,
    get() {return undefined;},
    set(value) {
      if (Object.hasOwn(this, 'structure')) registrations++;
      Object.defineProperty(this, name, {value, writable: true, enumerable: true, configurable: true});
    },
  });
  api = await import('./copied/module.wasm');
} finally {
  for (const [name, descriptor] of original) {
    if (descriptor) Object.defineProperty(Object.prototype, name, descriptor);
    else delete Object.prototype[name];
  }
}
assert.equal(registrations, 0);
const first = [1, 2], lists = [first];
assert.equal(api.lists(lists), lists); assert.deepEqual(first, [1, 2]);
assert.deepEqual(lists[1], [11, 2]); assert.notEqual(lists[1], first);
assert.equal(api.lists([null])[1], null);
const originalMap = new Map([['key', [2]]]), maps = [originalMap];
assert.equal(api.maps(maps), maps); assert.deepEqual(originalMap.get('key'), [2]);
assert.notEqual(maps[1], originalMap); assert.deepEqual(maps[1].get('key'), [12]);
const dictionary = {key: {\$1: 3, \$2: 'old'}}, dictionaries = [dictionary];
assert.equal(api.dictionaries(dictionaries), dictionaries);
assert.equal(dictionary.key.\$1, 3); assert.equal(dictionaries[1].key.\$1, 13);
assert.equal(dictionaries[1].key.\$2, null); assert.equal(Object.getPrototypeOf(dictionaries[1]), null);
const record = {\$1: 4, flags: [true], \$cost: 'price'}, records = [record];
assert.equal(api.records(records), records); assert.equal(record.flags[0], true);
assert.deepEqual(records[1], {\$1: 14, flags: [false], \$cost: 'price!'});
const key = [5], value = [6], keys = new Map([[key, value]]);
assert.equal(api.keys(keys), keys); assert.equal(keys.size, 2); assert.equal(keys.get(key), value);
assert.deepEqual([...keys][1], [[15], [6]]); assert.notEqual([...keys][1][1], value);
const wide = [[(1n << 62n) + 1n]]; assert.equal(api.wide(wide), wide);
assert.deepEqual(wide[1], wide[0]); assert.notEqual(wide[1], wide[0]);
assert.throws(() => api.wide([[1]]), TypeError);
assert.throws(() => api.wide([[1n << 63n]]), RangeError);
const named = [{id: 8, tag: 'first'}];
assert.equal(api.named(named), named); assert.deepEqual(named[1], {id: 9, tag: 'firsta'});
const reordered = [{tag: 'second', id: 9}];
assert.equal(api.reordered(reordered), reordered); assert.deepEqual(reordered[2], {id: 11, tag: 'secondb'});
assert.equal(api.reordered(named), named); assert.deepEqual(named[2], {id: 10, tag: 'firstb'});
const callback = [[7]]; assert.equal(await api.callback(async value => value, callback), callback);
assert.deepEqual(callback[1], [17]); assert.deepEqual(callback[0], [7]);
const resource = new api.Resource(30);
let closing;
const mixed = new Proxy([4], {getOwnPropertyDescriptor(target, key) {
  if (key === '0') {closing = resource.close(); assert.equal(api.cleanups(), 0);}
  return Reflect.getOwnPropertyDescriptor(target, key);
}});
assert.equal(await api.mixed(new Map([[resource, mixed]]), async () => assert.equal(api.cleanups(), 0)), 34);
await closing; assert.equal(api.cleanups(), 1);
''');
      final result = await Process.run('node', [
        'copied.mjs',
      ], workingDirectory: directory.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'binary policies load dependencies without making admission eager',
    () async {
      final module = await read('''
import 'dart:typed_data';
@NAPI() JsArray<Uint8List> bytes(JsArray<Uint8List> value) => value;
@NAPI(bigint: true) JsArray<Uint8List> same(JsArray<Uint8List> value) => value;
@NAPI() JsArray<ByteBuffer> buffers(JsArray<ByteBuffer> value) => value;
@NAPI() JsArray<Uint8List?> nullable(JsArray<Uint8List?> value) => value;
@NAPI() JsMap<ByteBuffer, JsArray<Uint8List>> map(JsMap<ByteBuffer, JsArray<Uint8List>> value) => value;
@NAPI() Future<JsArray<Uint8List>> callback(Future<JsArray<Uint8List>> Function(JsArray<Uint8List>) f, JsArray<Uint8List> value) => f(value);
@NAPI() JsArray<SharedBytes> shared(JsArray<SharedBytes> value) => value;
''');
      final wasm = lower(validate(module));
      final native = validateNative(module);
      final values = wasm.functions
          .take(4)
          .map((f) => f.inputs.single)
          .cast<JsCollectionConversion>()
          .toList();
      expect(values.first.value, isA<BinaryConversion>());
      expect(values[0].signatureKey, values[1].signatureKey);
      expect(values[0].signatureKey, isNot(values[2].signatureKey));
      expect(values[0].signatureKey, isNot(values[3].signatureKey));
      expect(
        values[0].signatureKey,
        isNot(
          (wasm.functions.last.inputs.single as JsCollectionConversion)
              .signatureKey,
        ),
      );
      expect(
        conversionGraph(wasm.conversions).whereType<BinaryConversion>(),
        isEmpty,
      );
      expect(
        conversionDependencies(wasm.conversions).whereType<BinaryConversion>(),
        isNotEmpty,
      );
      expect(native.hasBinary, isTrue);
      expect(native.hasSharedBytesTypes, isTrue);
      expect(emitBoundary(wasm), contains('function allocateBinary'));
      expect(emitDart(wasm), contains('JSAny _copyBinary'));
      expect(
        emitNativeDart(native),
        contains("import 'dart:typed_data' as typed_data;"),
      );
      expect(emitDeclarations(wasm), emitNativeDeclarations(native));
    },
  );

  test('pure binary handles copy values and work through callbacks', () async {
    final input = await File('${directory.path}/binary.dart').writeAsString('''
import 'dart:typed_data';
import 'package:napi/napi.dart';
@NAPI() JsArray<Uint8List> copy(JsArray<Uint8List> source) {
  source.set(1, source.get(0)!);
  return source;
}
@NAPI() JsMap<ByteBuffer, int> keys(JsMap<ByteBuffer, int> source) {
  final key = source.entries.first.\$1;
  if (source.has(key)) throw StateError('a copied key must be independent');
  source.set(key, 2);
  return source;
}
@NAPI() Future<JsArray<Uint8List>> callback(Future<JsArray<Uint8List>> Function(JsArray<Uint8List>) f, JsArray<Uint8List> source) async => copy(await f(source));
@NAPI() JsMap<SharedBytes, SharedBytes> views(JsMap<SharedBytes, SharedBytes> source) {
  final (key, value) = source.entries.first;
  if (!source.has(key) || !identical(source.get(key), value)) throw StateError('shared key identity changed');
  key[0] += 1;
  source.set(key, value);
  return source;
}
@NAPI() JsArray<SharedBytes> allocate(JsArray<SharedBytes> source) {
  source.set(0, SharedBytes.allocate(2)..[0] = 9);
  return source;
}
''');
    await buildLibrary(
      library: input.uri,
      output: Directory('${directory.path}/binary'),
      packagesPath: packages,
    );
    await File('${directory.path}/binary.mjs').writeAsString('''
import assert from 'node:assert/strict';
import * as api from './binary/module.wasm';
const bytes = new Uint8Array([1, 2]), source = [bytes];
assert.equal(api.copy(source), source);
assert.notEqual(source[1], bytes);
source[1][0] = 3; assert.equal(bytes[0], 1);
assert.equal(await api.callback(async value => value, source), source);
assert.throws(() => api.copy([null]), TypeError);
const key = new Uint8Array([5]).buffer, map = new Map([[key, 1]]);
assert.equal(api.keys(map), map); assert.equal(map.size, 2); assert.equal(map.get(key), 1);
const sharedKey = new Uint8Array([6]), sharedValue = new Uint8Array([7]);
const shared = new Map([[sharedKey, sharedValue]]);
assert.equal(api.views(shared), shared); assert.equal(shared.size, 1);
assert.equal(sharedKey[0], 7); assert.equal(shared.get(sharedKey), sharedValue);
const allocated = []; assert.equal(api.allocate(allocated), allocated);
assert.deepEqual([...allocated[0]], [9, 0]);
''');
    final result = await Process.run('node', [
      'binary.mjs',
    ], workingDirectory: directory.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('nested handle signatures retain deep element policies', () async {
    final module = await read('''
@NAPI() JsArray<JsMap<JsArray<int>, JsArray<T?>>?> nested<T>(JsArray<JsMap<JsArray<int>, JsArray<T?>>?> value) => value;
@NAPI() JsArray<JsMap<JsArray<int>, JsArray<U?>>?> renamed<U>(JsArray<JsMap<JsArray<int>, JsArray<U?>>?> value) => value;
@NAPI(bigint: true) JsArray<JsMap<JsArray<int>, JsArray<T?>>?> wide<T>(JsArray<JsMap<JsArray<int>, JsArray<T?>>?> value) => value;
''');
    final wasm = lower(validate(module));
    final native = validateNative(module);
    for (final inputs in [
      wasm.functions.map((f) => f.inputs.single),
      native.functions.map((f) => f.inputs.single),
    ]) {
      final values = inputs.cast<JsCollectionConversion>().toList();
      expect(values[0].value, isA<JsCollectionConversion>());
      expect(values[0].value.nullable, isTrue);
      expect(values[0].signatureKey, values[1].signatureKey);
      expect(values[0].signatureKey, isNot(values[2].signatureKey));
    }
    expect(emitDeclarations(wasm), emitNativeDeclarations(native));
  });

  test(
    'reference elements share class contracts and adapter identity policies',
    () async {
      final module = await read('''
@NAPI() class Box<T> { Box(this.value); T value; }
@NAPI() class Other { Other(); }
@NAPI() JsArray<Box<T>> boxes<T>(JsArray<Box<T>> value) => value;
@NAPI() JsArray<Box<U>> renamed<U>(JsArray<Box<U>> value) => value;
@NAPI() JsArray<Box<T>?> nullable<T>(JsArray<Box<T>?> value) => value;
@NAPI() JsMap<Box<T>, JsArray<Other?>> map<T>(JsMap<Box<T>, JsArray<Other?>> value) => value;
@NAPI() JsArray<Other> other(JsArray<Other> value) => value;
@NAPI() JsArray<Box<T>> callback<T>(JsArray<Box<T>> Function(JsArray<Box<T>>) f, JsArray<Box<T>> value) => f(value);
''');
      final wasm = lower(validate(module));
      final native = validateNative(module);
      for (final inputs in [
        wasm.functions.take(5).map((f) => f.inputs.single),
        native.functions.take(5).map((f) => f.inputs.single),
      ]) {
        final values = inputs.cast<JsCollectionConversion>().toList();
        expect(values[0].value, isA<ReferenceConversion>());
        expect(values[0].dartType, 'napi.JsArray<target.Box<_NapiHostValue>>');
        expect(values[0].typescriptType, 'globalThis.Array<Box<T>>');
        expect(values[0].signatureKey, values[1].signatureKey);
        expect(values[0].signatureKey, isNot(values[2].signatureKey));
        expect(values[0].signatureKey, isNot(values[4].signatureKey));
        expect(values[3].key, isA<ReferenceConversion>());
        expect(
          conversionGraph([values[0]]).whereType<ReferenceConversion>(),
          isEmpty,
        );
      }
      expect(emitDeclarations(wasm), emitNativeDeclarations(native));
      expect(emitBoundary(wasm), contains('"reference":0'));
      expect(
        emitNativeDart(native),
        contains('api.ownerValue(env, value, path, 0)'),
      );
      expect(
        emitDart(wasm),
        contains('toObject() as target.Box<_NapiHostValue>'),
      );
    },
  );

  for (final signature in [
    'JsArray<Box<T>> value',
    'JsArray<Box<T>> Function() callback',
    'JsArray<List<Dictionary<Box<T>>>> value',
    'JsArray<List<Dictionary<Box<T>>>> Function() callback',
  ]) {
    test(
      'reference handle names cannot shadow opaque parameters: $signature',
      () async {
        final module = await read('''
@NAPI(name: 'T') class Box<T> { Box(); }
@NAPI() int run<T>($signature) => 0;
''');
        for (final validateModule in [validate, validateNative]) {
          expect(
            () => validateModule(module),
            throwsA(
              isA<BindingDiagnostic>().having(
                (e) => e.code,
                'code',
                'NAPI_NAME',
              ),
            ),
          );
        }
      },
    );
  }

  test('direct opaque leaves retain raw values and logical TS types', () async {
    final module = await read('''
@NAPI() JsArray<T> array<T>(JsArray<T> value) => value;
@NAPI() JsArray<U> renamed<U>(JsArray<U> value) => value;
@NAPI() JsArray<T?> nullable<T>(JsArray<T?> value) => value;
@NAPI() JsMap<K, V> map<K, V>(JsMap<K, V> value) => value;
@NAPI() JsMap<String, T> mixed<T>(JsMap<String, T> value) => value;
@NAPI() Future<JsArray<T>> later<T>(JsArray<T> value) async => value;
@NAPI() Stream<JsArray<T>> events<T>(JsArray<T> value) => Stream.value(value);
@NAPI() class Holder<T> {
  Holder(this.items);
  JsArray<T> items;
  T? get(int index) => items.get(index);
}
''');
    final wasm = lower(validate(module));
    final native = validateNative(module);
    for (final conversions in [
      wasm.functions.map((f) => f.inputs.single),
      native.functions.map((f) => f.inputs.single),
    ]) {
      final values = conversions.cast<JsCollectionConversion>().toList();
      expect(values[0].value, isA<OpaqueConversion>());
      expect(values[0].dartType, 'napi.JsArray<_NapiHostValue>');
      expect(values[0].signatureKey, values[1].signatureKey);
      expect(values[0].signatureKey, isNot(values[2].signatureKey));
      expect(values[2].value.nullable, isTrue);
      expect(values[3].key, isA<OpaqueConversion>());
      expect(values[4].key, isA<ScalarConversion>());
    }
    expect(emitDeclarations(wasm), emitNativeDeclarations(native));
    expect(emitDeclarations(wasm), contains('globalThis.Array<T>'));
    expect(emitDeclarations(wasm), contains('globalThis.Map<K, V>'));
    expect(
      emitDart(wasm),
      contains('_JsElement<_NapiHostValue>(true, null, null)'),
    );
    expect(emitNativeDart(native), contains('NativeJsElement<_NapiHostValue>'));
    expect(emitBoundary(wasm), contains('"opaque":true'));
  });

  test(
    'Wasm opaque collection access and iteration instantiate and run',
    () async {
      final input = await File('${directory.path}/business.dart')
          .writeAsString('''
import 'package:napi/napi.dart';
@NAPI() V first<K,V>(JsMap<K,V> map) => map.entries.first.\$2;
@NAPI() T? get<T>(JsArray<T> array) => array.get(0);
@NAPI() int scalar(JsMap<String,int> map) => map.entries.first.\$2;
@NAPI() class Item { Item(this.value); int value; }
@NAPI() Item? reference(JsArray<Item> items) => items.get(0);
@NAPI() T deep<T>(JsArray<JsMap<String, JsArray<T>>> values) => values.get(0)!.get('items')!.get(0) as T;
''');
      await buildLibrary(
        library: input.uri,
        output: Directory('${directory.path}/module'),
        packagesPath: packages,
      );
      await File('${directory.path}/check.mjs').writeAsString('''
import assert from 'node:assert/strict';
import * as api from './module/module.wasm';
const object = {};
assert.equal(api.first(new Map([[null, undefined]])), undefined);
assert.equal(api.first(new Map([[undefined, object]])), object);
assert.equal(api.get([undefined]), undefined);
assert.equal(api.get([]), null);
assert.equal(api.scalar(new Map([['a', 7]])), 7);
const item = new api.Item(11);
assert.equal(api.reference([item]), item);
assert.throws(() => api.reference([null]), TypeError);
for (const value of [null, undefined, object]) {
  assert.equal(api.deep([new Map([['items', [value]]])]), value);
}
''');
      final result = await Process.run('node', [
        'check.mjs',
      ], workingDirectory: directory.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  for (final source in [
    '@NAPI() JsMap<Object, int> bad(JsMap<Object, int> value) => value;',
    '@NAPI() Map<JsArray<int>, int> bad(Map<JsArray<int>, int> value) => value;',
    '@NAPI() Map<(JsMap<String,int>,), int> bad(Map<(JsMap<String,int>,), int> value) => value;',
    '@NAPI() JsArray<Map<T, int>> bad<T>(JsArray<Map<T, int>> value) => value;',
    '@NAPI() JsArray<Map<(List<T>,), int>> bad<T>(JsArray<Map<(List<T>,), int>> value) => value;',
    '@NAPI() JsArray<Map<JsArray<int>, int>> bad(JsArray<Map<JsArray<int>, int>> value) => value;',
    '@NAPI() JsArray<Map<({JsMap<String, int> key}), int>> bad(JsArray<Map<({JsMap<String, int> key}), int>> value) => value;',
    '@NAPI() void bad<T>(JsArray<Map<T, int>> Function() callback) {}',
    '@NAPI() void bad(JsArray<Map<JsArray<int>, int>> Function() callback) {}',
    '@NAPI() JsArray<Set<int>> bad(JsArray<Set<int>> value) => value;',
    "import 'dart:typed_data'; @NAPI() JsArray<List<Uint16List>> bad(JsArray<List<Uint16List>> value) => value;",
    '@NAPI(classPolicy: ClassPolicy.value) class Value<T> { Value(this.n); final T n; } @NAPI() JsArray<Value<int>> bad(JsArray<Value<int>> value) => value;',
    '@NAPI() JsArray<Future<T>> bad<T>(JsArray<Future<T>> value) => value;',
    '@NAPI() JsArray<Stream<T>> bad<T>(JsArray<Stream<T>> value) => value;',
    '@NAPI(classPolicy: ClassPolicy.value) class Packet { Packet(this.items); final JsArray<int> items; } @NAPI() Map<Packet,int> bad(Map<Packet,int> value) => value;',
    '@NAPI(classPolicy: ClassPolicy.value) class Packet { Packet(this.items); final JsArray<int> items; } @NAPI() (Packet, Map<Packet,int>) bad((Packet, Map<Packet,int>) value) => value;',
  ]) {
    test('unsupported payload is diagnostic: $source', () async {
      final module = await read(source);
      for (final validateModule in [validate, validateNative]) {
        expect(() => validateModule(module), throwsA(isA<BindingDiagnostic>()));
      }
    });
  }
}
