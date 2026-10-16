import 'dart:io';

import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/native/loader.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late NativeModulePlan plan;
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('napi native loader ');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/business.dart');
    await source.writeAsString('''
import 'package:napi/napi.dart';
@NAPI() int add(int a, int b) => a + b;
@NAPI() class Counter {
  Counter(int value) : _value = value;
  Counter.named(int value) : this(value);
  int _value;
  @NAPI(name: 'increment') int advance(int delta) => _value += delta;
  int get value => _value;
  set value(int next) { _value = next; }
  static int sum(int a, int b) => a + b;
  static int count = 0;
  @NAPI(name: 'constructor') static int kind() => 42;
}
''');
    plan = validateNative(
      await AnnotationFrontend(
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
        native: true,
      ).read(source.uri),
    );
  });

  test('function-only loaders have no class callable work', () {
    final loader = emitNativeLoader(['add']);
    expect(loader, isNot(contains(r'$napiCallable')));
    expect(loader, contains(r'export {$napi0 as add}'));
  });

  test('loader decorates only planned class methods and accessors', () async {
    await File('${directory.path}/module.mjs').writeAsString(
      emitNativeLoader(['Counter', 'add'], classes: plan.classes),
    );
    // A fake .node loader supplies ordinary constructible callbacks without a
    // native VM. The generated public loader itself runs without modification.
    await File('${directory.path}/preload.cjs').writeAsString(r'''
Object.defineProperty(process, 'platform', {value: 'darwin'});
Object.defineProperty(process, 'arch', {value: 'arm64'});
require.extensions['.node'] = require.extensions['.js'];
''');
    await File('${directory.path}/bridge.node').writeAsString(r'''
const brands = new WeakSet();
const calls = [];
const sentinel = new Error('original callback failure');
let count = 0;
function Counter(value) {
  if (!new.target) throw new TypeError('constructor requires new');
  brands.add(this);
  this.current = value;
}
function check(receiver) {
  if (!brands.has(receiver)) throw new TypeError('invalid receiver');
}
function increment(delta) {
  check(this);
  calls.push({kind: 'increment', receiver: this, args: Array.from(arguments)});
  if (delta === 'fail') throw sentinel;
  return this.current += delta;
}
function sum(a, b) {
  calls.push({kind: 'sum', receiver: this, args: Array.from(arguments)});
  return a + b;
}
// Node-API static method callbacks currently have empty names.
Object.defineProperty(sum, 'name', {value: '', configurable: true});
function named(value) {
  calls.push({kind: 'named', receiver: this, args: Array.from(arguments)});
  return new Counter(value);
}
function kind() { return 42; }
Object.defineProperty(kind, 'name', {value: 'constructor', configurable: true});
function getValue() {
  check(this);
  calls.push({kind: 'get', receiver: this, args: Array.from(arguments)});
  return this.current;
}
function setValue(value) {
  check(this);
  calls.push({kind: 'set', receiver: this, args: Array.from(arguments)});
  this.current = value;
}
function getCount() { return count; }
function setCount(value) { count = value; }
for (const callback of [getValue, setValue, getCount, setCount]) {
  Object.defineProperty(callback, 'name', {value: '', configurable: true});
}
const method = callback => ({value: callback, writable: true, configurable: true});
Object.defineProperties(Counter.prototype, {
  increment: method(increment),
  value: {get: getValue, set: setValue, configurable: true},
});
Object.defineProperties(Counter, {
  sum: method(sum),
  named: method(named),
  constructor: method(kind),
  count: {get: getCount, set: setCount, configurable: true},
  unselected: {get() { throw new Error('unselected accessor must not run'); }},
});
function add(a, b) { return a + b; }
const originals = [
  [Counter.prototype, 'increment', 'value'],
  [Counter.prototype, 'value', 'get'],
  [Counter.prototype, 'value', 'set'],
  [Counter, 'sum', 'value'],
  [Counter, 'named', 'value'],
  [Counter, 'constructor', 'value'],
  [Counter, 'count', 'get'],
  [Counter, 'count', 'set'],
].map(([target, name, kind]) => {
  const descriptor = Object.getOwnPropertyDescriptor(target, name);
  return {target, name, kind, descriptor, callback: descriptor[kind]};
});
globalThis.nativeFixture = {Counter, add, originals, calls, sentinel};
exports.load = () => ({Counter, add});
''');
    await File('${directory.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import {Counter, add} from './module.mjs';
const fixture = globalThis.nativeFixture;
assert.equal(Counter, fixture.Counter);
assert.equal(add, fixture.add);
assert(Object.hasOwn(Counter, 'prototype'));
assert.equal(Object.getPrototypeOf(Reflect.construct(Object, [], Counter)), Counter.prototype);
assert(Object.hasOwn(add, 'prototype'));
assert.equal(add(2, 3), 5);
for (const {target, name, kind, descriptor: before, callback} of fixture.originals) {
  const after = Object.getOwnPropertyDescriptor(target, name);
  const fn = after[kind];
  assert.notEqual(fn, callback);
  assert.equal(after.enumerable, before.enumerable);
  assert.equal(after.configurable, before.configurable);
  if (kind === 'value') assert.equal(after.writable, before.writable);
  assert.equal(fn.name, kind === 'value' ? name : kind + ' ' + name);
  assert.equal(fn.length, callback.length);
  for (const key of ['name', 'length']) {
    const original = Object.getOwnPropertyDescriptor(callback, key);
    const wrapped = Object.getOwnPropertyDescriptor(fn, key);
    for (const flag of ['writable', 'enumerable', 'configurable']) {
      assert.equal(wrapped[flag], original[flag]);
    }
  }
  assert.equal(Object.hasOwn(fn, 'prototype'), false);
  assert.throws(() => Reflect.construct(Object, [], fn), TypeError);
  assert.throws(() => Reflect.construct(Object, [], fn.bind(null)), TypeError);
  assert.throws(() => new fn(), TypeError);
}
assert.equal(fixture.calls.length, 0);
const counter = new Counter(10);
assert.equal(counter.increment(2, undefined, 'extra'), 12);
assert.deepEqual(fixture.calls.at(-1).args, [2, undefined, 'extra']);
assert.equal(fixture.calls.at(-1).receiver, counter);
assert.throws(() => counter.increment('fail'), error => error === fixture.sentinel);
assert.equal(counter.increment(1), 13);
const increment = counter.increment;
assert.throws(() => increment(1), TypeError);
for (const receiver of [{}, Object.create(Counter.prototype), new Proxy(counter, {})]) {
  assert.throws(() => increment.call(receiver, 1), TypeError);
}
const marker = {};
assert.equal(Counter.sum.call(marker, 2, 3, 4), 5);
assert.equal(fixture.calls.at(-1).receiver, marker);
assert.deepEqual(fixture.calls.at(-1).args, [2, 3, 4]);
const value = Object.getOwnPropertyDescriptor(Counter.prototype, 'value');
assert.equal(value.get.call(counter, 'extra'), 13);
assert.deepEqual(fixture.calls.at(-1).args, ['extra']);
value.set.call(counter, 20, 'extra');
assert.deepEqual(fixture.calls.at(-1).args, [20, 'extra']);
assert.equal(counter.value, 20);
counter.value = 21;
assert.equal(counter.value, 21);
Counter.count = 7;
assert.equal(Counter.count, 7);
assert.equal(Counter.constructor(), 42);
const named = Counter.named(30);
assert(named instanceof Counter);
assert.equal(named.value, 30);
const apply = Reflect.apply;
try {
  Reflect.apply = () => { throw new Error('late patched Reflect.apply'); };
  assert.equal(counter.increment(1), 22);
} finally {
  Reflect.apply = apply;
}
console.log('selected native class callable forwarding passed');
''');
    final result = await Process.run('node', [
      '--require',
      '${directory.path}/preload.cjs',
      '${directory.path}/check.mjs',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  });
}
