import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;

const _source = '''
import 'dart:async';
import 'package:napi/napi.dart';

@NAPI()
class Router<T> {
  Router([this.value]);
  Router.from(T input) : value = input;
  T? value;
  T accept(T input) => input;
  T named({required T input}) => input;
  Router<T> same(Router<T> other) => other;
  Router<T> copy() => Router<T>(value);
  Future<int> wait(T input) => Completer<int>().future;
  static int count() => 1;
}

@NAPI()
class Empty<T> {
  Empty();
}

@NAPI() T echo<T>(T value) => value;
@NAPI() T? optional<T>([T? value]) => value;
@NAPI() T named<T>({required T value}) => value;
@NAPI() T? optionalNamed<T>(int index, {T? first, T? second, int fallback = 7}) => index == 0 ? first : second;
@NAPI() T ordered<T>(T value, int requiredSecond) => value;
@NAPI() Future<int> wait<T>(T value) => Completer<int>().future;
@NAPI() Router<T> same<T>(Router<T> value) => value;
@NAPI() B second<A, B>(A first, B second) => second;
''';

const _resourceSource = '''
import 'package:napi/napi.dart';
final _closed = <int, int>{};
final _reasons = <int, Object?>{};
final _nullReasons = <int, bool>{};
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource<T> {
  Resource(this.id, this.value);
  final int id;
  T value;
  T echo(T next) => next;
  int checked((T, int) input) => input.\$2;
  Future<T> later(Future<void> Function() gate) async {
    await gate();
    return value;
  }
  Stream<T> events(Future<void> Function() gate) async* {
    await gate();
    yield value;
  }
  Future<void> close([T? reason]) async {
    _closed[id] = (_closed[id] ?? 0) + 1;
    _reasons[id] = reason;
    _nullReasons[id] = reason == null;
  }
}
@NAPI() int closed(int id) => _closed[id] ?? 0;
@NAPI() T? reason<T>(int id) => _reasons[id] as T?;
@NAPI() bool nullReason(int id) => _nullReasons[id] ?? false;
''';

const _resourceChecks = r'''
import assert from 'node:assert/strict';
import {setImmediate as tick} from 'node:timers/promises';
const api = await import(process.argv[2]);
let id = 0;
for (const value of [undefined, null, {}, Symbol('payload')]) {
  const resource = new api.Resource(++id, value);
  assert.equal(resource.value, value);
  assert.equal(resource.echo(value), value);
  await resource.close(value);
  assert.equal(api.closed(id), 1);
  assert.equal(api.reason(id), value);
  assert.equal(api.nullReason(id), false);
}
const omitted = new api.Resource(10, undefined);
await omitted.close();
assert.equal(api.nullReason(10), true);

for (const stream of [false, true]) {
  const payload = {};
  const resourceId = stream ? 21 : 20;
  const resource = new api.Resource(resourceId, payload);
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  let entered;
  const started = new Promise(resolve => { entered = resolve; });
  const wait = () => { entered(); return gate; };
  const pending = stream
    ? resource.events(wait).next()
    : resource.later(wait);
  await started;
  let finished = false;
  const closing = resource.close(payload).then(() => { finished = true; });
  await tick();
  assert.equal(finished, false);
  assert.equal(api.closed(resourceId), 0);
  release();
  const result = await pending;
  if (stream) assert.equal(result.done, true);
  else assert.equal(result, payload);
  await closing;
  assert.equal(api.closed(resourceId), 1);
  assert.equal(api.reason(resourceId), payload);
}

const resource = new api.Resource(30, undefined);
let weak;
(() => {
  const value = {};
  weak = new WeakRef(value);
  assert.throws(() => resource.checked({$1: value, $2: 'invalid'}), TypeError);
})();
for (let attempt = 0; attempt < 40; attempt++) {
  await tick();
  global.gc();
  await tick();
  if (weak.deref() === undefined) break;
}
assert.equal(weak.deref(), undefined);
await resource.close();
assert.equal(api.closed(30), 1);
''';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-native-opaque-');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<NativeModulePlan> plan(String source) async {
    final input = File('${directory.path}/business.dart');
    await input.writeAsString(source);
    return validateNative(
      await AnnotationFrontend(
        packagesPath: _packages,
        native: true,
      ).read(input.uri),
    );
  }

  test(
    'opaque classes and functions compile as real carrier generics',
    () async {
      final module = await plan(_source);
      final dart = emitNativeDart(module);
      expect(dart, contains('typedef _NapiHostValue = NativeHostValue;'));
      expect(dart, contains('target.Router<_NapiHostValue>(a0)'));
      expect(dart, contains('target.Router<_NapiHostValue>.from(a0)'));
      expect(dart, contains('target.Empty<_NapiHostValue>()'));
      expect(dart, contains('target.Router.count()'));
      expect(dart, contains('object is! target.Router<_NapiHostValue>'));
      expect(dart, contains('object0 is! target.Router<_NapiHostValue>'));
      expect(dart, contains('target.echo<_NapiHostValue>(a0)'));
      expect(
        dart,
        contains('target.second<_NapiHostValue, _NapiHostValue>(a0, a1)'),
      );
      expect(dart, contains('_api.retainFuture(token, [a0])'));
      expect(dart, contains('_api.retainFuture(token, [object, a0])'));
      expect(dart, contains('return _api.hostValue(call.env, value).address;'));
      expect(dart, isNot(contains(' is target.Router)')));
      expect(dart, isNot(contains('target.Router<dynamic>')));

      final entry = File('${directory.path}/entry.dart');
      await entry.writeAsString(dart);
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
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('opaque presence is checked before owning supplied values', () async {
    final module = await plan(_source);
    final dart = emitNativeDart(module);
    String body(String name) {
      final call = module.functions.singleWhere((f) => f.exportName == name);
      return dart.split('int ${call.callback}(').last.split('\n}\n').first;
    }

    final required = body('ordered');
    expect(
      required,
      contains('_api.presentArgument(call, 0, "ordered.value")'),
    );
    expect(
      required.indexOf('_api.requiredArgument(call, 1,'),
      lessThan(required.indexOf('_api.ownHostValue(call.env, raw0)')),
    );
    expect(required, isNot(contains('_api.isNull')));
    final optional = body('optional');
    expect(optional, contains('final default0 = 0 >= call.argumentCount;'));
    expect(optional, contains('a0 = null;'));
    expect(optional, isNot(contains('omittedOrUndefined')));
    expect(body('named'), contains('_api.presentOption(options, 0,'));
    final named = body('optionalNamed');
    expect(named, contains('final default1 = !options.present[0];'));
    expect(named, contains('final default2 = !options.present[1];'));
    expect(
      named,
      contains('final raw1 = default1 ? nullptr : options.values[0];'),
    );
    expect(
      named,
      contains('final raw2 = default2 ? nullptr : options.values[1];'),
    );
    expect(
      named,
      contains('final default3 = _api.defaultOption(call.env, options, 2);'),
    );
    expect(named, isNot(contains('>= call.argumentCount')));
  });

  test('ordinary modules do not emit the opaque carrier', () async {
    final dart = emitNativeDart(
      await plan('''
import 'package:napi/napi.dart';
@NAPI() int count(int value) => value;
'''),
    );
    expect(dart, isNot(contains('_NapiHostValue')));
    expect(dart, isNot(contains('ownHostValue')));
  });

  final runtime = Platform.environment['NAPI_TEST_NATIVE_RUNTIME'];
  for (final target in BuildTarget.values) {
    test(
      'generic resources preserve payloads and operation leases (${target.name})',
      () async {
        final root = Directory(await directory.resolveSymbolicLinks());
        final source = await File('${root.path}/business.dart')
            .writeAsString(_resourceSource);
        final module = await buildLibrary(
          library: source.uri,
          output: Directory('${root.path}/module'),
          packagesPath: _packages,
          target: target,
          nativeRuntime: target == BuildTarget.native
              ? Directory(runtime!)
              : null,
        );
        final checks = await File('${root.path}/check.mjs')
            .writeAsString(_resourceChecks);
        final executed = await Process.run(
          Platform.environment['NAPI_TEST_NODE'] ?? 'node',
          ['--expose-gc', checks.path, module.entrypoint.uri.toString()],
        );
        expect(
          executed.exitCode,
          0,
          reason: '${executed.stdout}${executed.stderr}',
        );
      },
      skip: target == BuildTarget.native && runtime == null
          ? 'Set NAPI_TEST_NATIVE_RUNTIME to an ABI15 bundle.'
          : false,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
