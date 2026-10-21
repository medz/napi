import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Wasm function values preserve contracts, defaults and identity',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'napi-wasm-functions-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final source = await File('${temporary.path}/business.dart')
          .writeAsString('''
import 'package:napi/napi.dart';
typedef Unary = int Function(int);
final Unary canonical = (value) => value + 2;
@NAPI() Unary getFunction() => canonical;
@NAPI() Unary make(int delta) => (value) => value + delta;
@NAPI() Unary echo(Unary value) => value;
@NAPI() bool original(Unary value) => identical(value, canonical);
@NAPI() int Function([int, int]) optional() => ([int first = 2, int second = 3]) => first + second;
@NAPI() int Function({int value, String label}) named() => ({int value = 7, String label = 'abc'}) => value + label.length;
@NAPI() (List<Unary?>, Map<String, Unary>, Dictionary<Unary>) containers() => ([canonical, null], {'f': canonical}, Dictionary({'f': canonical}));
@NAPI() Unary Function(Unary) compose(int delta) => (function) => (value) => function(value) + delta;
@NAPI() Unary transform(Unary Function(Unary) callback) => callback(canonical);
@NAPI() Future<int> Function(int) asyncFunction() => (value) async => value + 4;
@NAPI() Future<Unary> future() async => canonical;
@NAPI() Stream<int> Function([int]) streamFunction() => ([int value = 4]) async* { yield value; yield value + 1; };
@NAPI() T Function() capture<T>(T value) => () => value;
@NAPI(classPolicy: ClassPolicy.value)
class Parsed { Parsed(String source) : value = int.parse(source); final int value; }
@NAPI() Parsed Function(Parsed) normalized() => (value) => Parsed((value.value + 1).toString());
@NAPI() Parsed Function(Parsed) echoNormalized(Parsed Function(Parsed) callback) => callback;
int closed = 0;
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource { Resource(this.value); final int value; void close() { closed++; } }
@NAPI() Future<Resource> Function(Resource) resourceFunction() => (value) async {
  await Future<void>.delayed(Duration.zero); return value;
};
@NAPI() int closedCount() => closed;
@NAPI() Stream<Resource> Function(Resource) resourceStream() => (value) async* {
  try { yield value; yield value; }
  finally { await Future<void>.delayed(Duration.zero); }
};
''');
      await buildLibrary(
        library: source.uri,
        output: Directory('${temporary.path}/module'),
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
      );
      await File('${temporary.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import * as api from './module/module.wasm';
const functionValue = api.getFunction();
assert.equal(functionValue(3), 5);
assert.equal(api.getFunction(), functionValue);
assert.equal(api.echo(functionValue), functionValue);
assert.equal(api.original(functionValue), true);
const host = value => value + 8;
assert.equal(api.echo(host), host);
assert.equal(api.make(7)(3), 10);
assert.throws(() => new functionValue(1), TypeError);
assert.throws(() => functionValue('wrong'), TypeError);
assert.throws(() => functionValue(), TypeError);
const optional = api.optional();
assert.equal(optional(), 5);
assert.equal(optional(4), 7);
assert.equal(optional(4, 8), 12);
assert.equal(optional(undefined), 5);
assert.equal(optional(4, undefined), 7);
assert.throws(() => optional(undefined, 8), TypeError);
const named = api.named();
assert.equal(named(), 10);
assert.equal(named({value: 2}), 5);
assert.equal(named({label: 'x'}), 8);
assert.equal(named({value: undefined}), 10);
assert.throws(() => named({value: null}), TypeError);
assert.throws(() => named({unknown: 1}), TypeError);
assert.throws(() => named({get value() { throw Error('must not read getter'); }}), TypeError);
const containers = api.containers();
assert.equal(containers.$1[0], functionValue);
assert.equal(containers.$1[1], null);
assert.equal(containers.$2.get('f'), functionValue);
assert.equal(containers.$3.f, functionValue);
assert.equal(api.compose(3)(host)(1), 12);
assert.equal(api.transform(value => { assert.equal(value, functionValue); return host; }), host);
assert.equal(await api.asyncFunction()(3), 7);
assert.equal(await api.future(), functionValue);
assert.deepEqual(await Array.fromAsync(api.streamFunction()()), [4, 5]);
assert.deepEqual(await Array.fromAsync(api.streamFunction()(8)), [8, 9]);
for (const value of [undefined, null, Symbol('opaque'), {x: 1}, host]) {
  assert.equal(api.capture(value)(), value);
}
assert.deepEqual(api.normalized()({source: '9'}), {value: 10});
const normalizedHost = value => ({source: String(value.value + 3)});
const normalizedFacade = api.echoNormalized(normalizedHost);
assert.notEqual(normalizedFacade, normalizedHost);
assert.equal(api.echoNormalized(normalizedHost), normalizedFacade);
assert.deepEqual(normalizedFacade({source: '4'}), {value: 7});
const resource = new api.Resource(11);
const pending = api.resourceFunction()(resource);
const cleanup = resource.close();
assert.equal(api.closedCount(), 0);
assert.equal(await pending, resource);
await cleanup;
assert.equal(api.closedCount(), 1);
const streamedResource = new api.Resource(12);
const iterator = api.resourceStream()(streamedResource);
assert.equal((await iterator.next()).value, streamedResource);
const cancellation = iterator.return();
const streamCleanup = streamedResource.close();
await cancellation;
await streamCleanup;
assert.equal(api.closedCount(), 2);
''');
      final result = await Process.run('node', [
        'check.mjs',
      ], workingDirectory: temporary.path);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('Wasm function-only modules load direct and nested contracts', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'napi-wasm-function-only-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final cases = [
      (
        name: 'direct',
        source: '''
@NAPI() int Function(int) makeAdder(int delta) => (value) => value + delta;
''',
        check: '''
const add = api.makeAdder(3);
assert.equal(add(4), 7);
assert.throws(() => add('4'), TypeError);
assert.throws(() => new add(4), TypeError);
''',
      ),
      (
        name: 'nested-output',
        source: '''
@NAPI() List<int Function(int)> functions() => [(value) => value + 3];
''',
        check: '''
const [add] = api.functions();
assert.equal(add(4), 7);
assert.throws(() => add('4'), TypeError);
''',
      ),
      (
        name: 'nested-input',
        source: '''
@NAPI() int invoke(List<int Function(int)> callbacks) => callbacks.single(4);
''',
        check: '''
assert.equal(api.invoke([value => value + 3]), 7);
assert.throws(() => api.invoke([() => '7']), TypeError);
''',
      ),
    ];
    for (final testCase in cases) {
      final directory = await Directory('${temporary.path}/${testCase.name}')
          .create();
      final source = await File(
        '${directory.path}/business.dart',
      ).writeAsString("import 'package:napi/napi.dart';\n${testCase.source}");
      await buildLibrary(
        library: source.uri,
        output: Directory('${directory.path}/module'),
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
      );
      await File('${directory.path}/check.mjs').writeAsString('''
import assert from 'node:assert/strict';
import * as api from './module/module.wasm';
${testCase.check}
''');
      final result = await Process.run('node', [
        'check.mjs',
      ], workingDirectory: directory.path);
      expect(
        result.exitCode,
        0,
        reason: '${testCase.name}: ${result.stdout}${result.stderr}',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
