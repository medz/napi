import 'dart:io';

import 'package:napi/build.dart';
import 'package:test/test.dart';

const _source = '''
import 'package:napi/napi.dart';
@NAPI() abstract class Left {
  factory Left([int value = 7]) => _Both(value);
  int left([int delta = 2]);
}
@NAPI() abstract class Right {
  Right._();
  int right();
  int get amount;
  set amount(int value);
}
@NAPI() abstract class DifferentDefault {
  DifferentDefault._();
  int left([int delta = 99]);
}
class _Both implements Left, Right {
  _Both(this.amount);
  int amount;
  int left([int delta = 2]) => amount + delta;
  int right() => amount * 2;
}
class _Conflict implements Left, DifferentDefault {
  int left([int delta = 2]) => delta;
}
final _shared = _Both(7);
final _gc = _Both(21);
@NAPI() Left asLeft() => _shared;
@NAPI() Right asRight() => _shared;
@NAPI() Right roundTrip(Left input) => input as Right;
@NAPI() Left conflicting() => _Conflict();
@NAPI() Left gcLeft() => _gc;
''';

const _consumer = r'''
import assert from 'node:assert/strict';
const api = await import('./built/module.mjs');
for (let i = 0; i < 2; i++) {
  assert.throws(() => api.conflicting(), error =>
    error instanceof TypeError && /conflicting result/.test(error.message));
}
const a = api.asLeft();
assert.equal(api.asRight(), a);
assert.equal(api.roundTrip(a), a);
assert.equal(a.constructor, Object);
assert.equal(a instanceof api.Left, false);
assert.equal(a instanceof api.Right, false);
assert.equal(a.left(), 9);
assert.equal(a.right(), 14);
a.amount = 12;
assert.equal(a.amount, 12);
assert.equal(api.Left.prototype.left.call(a), 14);
assert.equal(api.Right.prototype.right.call(a), 24);
for (const invalid of [{}, Object.create(Object.getPrototypeOf(a)), new Proxy(a, {})]) {
  assert.throws(() => api.Left.prototype.left.call(invalid), TypeError);
}
const fresh = new api.Left(4);
assert.equal(fresh.left(), 6);
assert.equal(fresh.right(), 8);
assert.equal(fresh.constructor, Object);
class Derived extends api.Left {
  #secret = 3;
  left(delta = 2) { return super.left(delta) + 100; }
  secret() { return this.#secret; }
}
const derived = new Derived(8);
assert.equal(Object.getPrototypeOf(derived), Derived.prototype);
assert.equal(derived.left(), 110);
assert.equal(derived.secret(), 3);
assert.equal(api.Right.prototype.right.call(derived), 16);
assert.equal(derived.right, undefined);
function seed() {
  const value = api.gcLeft();
  assert.equal(value.right(), 42);
  return new WeakRef(value);
}
const weak = seed();
for (let i = 0; i < 80; i++) {
  await new Promise(setImmediate);
  global.gc();
  await new Promise(setImmediate);
  if (!weak.deref()) break;
}
assert.equal(weak.deref(), undefined);
const replacement = api.gcLeft();
assert.equal(replacement.right(), 42);
assert.equal(api.roundTrip(replacement), replacement);
console.log('native composite creation, registration recovery and readoption passed');
''';

void main() {
  final runtime = Platform.environment['NAPI_TEST_NATIVE_RUNTIME'];
  test(
    'real native composite shapes preserve callbacks, custom new.target and GC',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'napi-native-views-',
      );
      final root = Directory(await temporary.resolveSymbolicLinks());
      addTearDown(() => root.delete(recursive: true));
      final source = File('${root.path}/business.dart');
      await source.writeAsString(_source);
      await buildLibrary(
        library: source.uri,
        output: Directory('${root.path}/built'),
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
        target: BuildTarget.native,
        nativeRuntime: Directory(runtime!),
      );
      final script = File('${root.path}/consumer.mjs');
      await script.writeAsString(_consumer);
      final result = await Process.run(
        Platform.environment['NAPI_TEST_NODE'] ?? 'node',
        ['--expose-gc', script.path],
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    },
    skip: runtime == null
        ? 'Set NAPI_TEST_NATIVE_RUNTIME to an ABI9 bundle.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
