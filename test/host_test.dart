import 'dart:io';

import 'package:napi/src/host.dart';
import 'package:napi/src/wasm.dart';
import 'package:test/test.dart';

void main() {
  WasmImport bridgeImport(String name, [int index = 0]) => WasmImport(
    module: 'napi',
    name: name,
    kind: WasmImportKind.function,
    alias: '_i$index',
  );

  test(
    'record/map prototype validation is emitted once and only when used',
    () {
      final scalar = generateHost(_compiler, [bridgeImport('kind')]);
      expect(scalar, isNot(contains('napiRequireObject')));
      expect(scalar, isNot(contains('napi.snapshotRecord')));
      final records = generateHost(_compiler, [bridgeImport('snapshotRecord')]);
      expect(records, contains('napi.snapshotRecord ='));
      expect(records, isNot(contains('napi.snapshotMap =')));
      final both = generateHost(_compiler, [
        bridgeImport('snapshotRecord'),
        bridgeImport('snapshotMap', 1),
      ]);
      expect(
        RegExp(r'function napiRequireObject\(').allMatches(both).length,
        1,
      );
    },
  );

  test(
    'record descriptor snapshots and shared map validation execute correctly',
    () async {
      final host =
          generateHost(_compiler, [
            bridgeImport('snapshotRecord'),
            bridgeImport('snapshotMap', 1),
            bridgeImport('newMap', 2),
            bridgeImport('mapSet', 3),
            bridgeImport('arrayGet', 4),
            bridgeImport('arraySet', 5),
            bridgeImport('newList', 6),
          ]).replaceFirst(
            RegExp(
              r'^import \* as dartExports from [^\n]+;\n',
              multiLine: true,
            ),
            'const dartExports = {};\n',
          );
      final node =
          Platform.environment['NAPI_NODE22'] ??
          Platform.environment['NAPI_NODE'] ??
          'node';
      final result = await Process.run(node, [
        '--input-type=module',
        '--eval',
        '$host\n$_assertions',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, 'host snapshots passed\n');
    },
  );
}

// Exercise the actual generated host helper bodies without compiling a second
// Wasm fixture. The runtime suites separately test the real bridge/import cycle.
const _compiler = '''
    let dartInstance;
    const compilerHelper = null;
    const dart2wasm = {
      exceptionStack: (exn) => {
        if (exn instanceof Error) {
          return exn.stack;
        } else {
          return null;
        }
      },
    };
    const baseImports = {
    };
    const jsStringPolyfill = {
''';

const _assertions = r'''
import assert from 'node:assert/strict';
import vm from 'node:vm';
const snapshotRecord = _i0;
const snapshotMap = _i1;
const names = ['id', 'name'];
let getters = 0;
const hidden = Object.create(null, {
  id: {value: 1}, name: {value: 'hidden'},
  extra: {enumerable: true, get() { getters++; throw new Error('unused'); }},
});
assert.deepEqual(snapshotRecord(hidden, names, 'parameter user'), [1, 'hidden']);
assert.equal(getters, 0);
const source = {id: 2, name: 'before'};
const copy = snapshotRecord(source, names, 'parameter user');
source.id = 3;
assert.deepEqual(copy, [2, 'before']);
const noExtras = new Proxy(source, {
  ownKeys() { throw new Error('do not enumerate'); },
  get() { throw new Error('do not read'); },
  getOwnPropertyDescriptor(target, key) {
    assert.equal(names.includes(key), true);
    return Reflect.getOwnPropertyDescriptor(target, key);
  },
});
assert.deepEqual(snapshotRecord(noExtras, names, 'parameter user'), [3, 'before']);
assert.deepEqual(snapshotRecord(vm.runInNewContext('({id:4,name:"realm"})'), names, 'parameter user'), [4, 'realm']);
assert.deepEqual(snapshotMap(vm.runInNewContext('({id:4,name:"realm"})'), 'parameter map'), ['id', 4, 'name', 'realm']);
for (const value of [null, [], new Date(), new Map(), new (class User {id=1;name='class';})(), Object.create({id:1,name:'custom'})]) {
  assert.throws(() => snapshotRecord(value, names, 'parameter user'), TypeError);
  assert.throws(() => snapshotMap(value, 'parameter map'), TypeError);
}
assert.throws(() => snapshotRecord({name:'missing'}, names, 'parameter user'), error => error instanceof TypeError && error.message.includes('parameter user["id"]'));
const accessors = {name:'known', get id() {getters++; throw new Error('not invoked');}};
assert.throws(() => snapshotRecord(accessors, names, 'parameter user'), TypeError);
assert.equal(getters, 0);
assert.throws(() => snapshotMap(hidden, 'parameter map'), TypeError);
assert.equal(getters, 0);
assert.deepEqual(snapshotMap(Object.create(null, {hidden: {value: 1}}), 'parameter map'), []);
for (const trap of ['getPrototypeOf', 'getOwnPropertyDescriptor']) {
  const original = new Error(trap);
  const proxy = new Proxy(source, {[trap]() {throw original;}});
  assert.throws(() => snapshotRecord(proxy, names, 'parameter user'), error => error === original);
  assert.throws(() => snapshotMap(proxy, 'parameter map'), error => error === original);
}
const constructor = Object.getOwnPropertyDescriptor(Object.prototype, 'constructor');
try {
  Object.defineProperty(Object.prototype, 'constructor', {get() {throw new Error('unused root getter');}, configurable: true});
  assert.deepEqual(snapshotRecord(source, names, 'parameter user'), [3, 'before']);
  assert.deepEqual(snapshotMap(source, 'parameter map'), ['id', 3, 'name', 'before']);
} finally {
  Object.defineProperty(Object.prototype, 'constructor', constructor);
}
const output = _i2();
_i3(output, 'constructor', 'value');
_i3(output, 'then', false);
_i3(output, '__proto__', 'data');
assert.equal(Object.getPrototypeOf(output), null);
assert.deepEqual(Object.keys(output), ['constructor', 'then', '__proto__']);
assert.equal(output.__proto__, 'data');
assert.deepEqual(Object.getOwnPropertyDescriptor(output, 'then'), {value: false, writable: true, enumerable: true, configurable: true});
// Wasm i32 imports expose signed numbers; array indices/lengths are unsigned.
// Keep these arrays sparse: inspect only the specified properties, no traversal.
const high = _i6(-0x80000000);
assert.equal(high.length, 0x80000000);
_i5(high, -0x80000000, 'high');
assert.equal(high.length, 0x80000001);
assert.equal(_i4(high, -0x80000000), 'high');
assert.equal(Object.hasOwn(high, '-2147483648'), false);
const largest = _i6(-1);
assert.equal(largest.length, 0xffffffff);
_i5(largest, -2, 'last index');
assert.equal(_i4(largest, -2), 'last index');
assert.equal(largest.length, 0xffffffff);
assert.equal(Object.hasOwn(largest, '-2'), false);
_i5(largest, -1, 'non-index data key');
assert.equal(_i4(largest, -1), 'non-index data key');
assert.equal(Object.hasOwn(largest, '-1'), false);
assert.equal(largest.length, 0xffffffff);
console.log('host snapshots passed');
''';
