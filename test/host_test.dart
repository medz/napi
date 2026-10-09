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

  test(
    'record byte copy diagnostics are emitted only for their own import',
    () {
      for (final imports in [
        [bridgeImport('kind'), bridgeImport('copyBytes', 1)],
        [bridgeImport('snapshotRecord')],
        [bridgeImport('snapshotList')],
        [bridgeImport('snapshotMap')],
      ]) {
        expect(
          generateHost(_compiler, imports),
          isNot(contains('copyRecordBytes')),
        );
      }
      final host = generateHost(_compiler, [bridgeImport('copyRecordBytes')]);
      expect(host, contains('napi.copyRecordBytes ='));
      expect(host, isNot(contains('napiRequireObject')));
    },
  );

  test('record byte copies preserve views, getters, ownership and exception policy', () async {
    final host =
        generateHost(_compiler, [
          bridgeImport('kind'),
          bridgeImport('copyRecordBytes', 1),
          bridgeImport('snapshotRecord', 2),
        ]).replaceFirst(
          RegExp(r'^import \* as dartExports from [^\n]+;\n', multiLine: true),
          'const dartExports = {};\n',
        );
    final node =
        Platform.environment['NAPI_NODE22'] ??
        Platform.environment['NAPI_NODE'] ??
        'node';
    final result = await Process.run(node, [
      '--input-type=module',
      '--eval',
      '$host\n$_byteAssertions',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(result.stdout, 'host byte copies passed\n');
  });
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

const _byteAssertions = r'''
import assert from 'node:assert/strict';
import vm from 'node:vm';
const kind = _i0;
const copy = _i1;
const snapshotRecord = _i2;
const context = 'parameter packets[1]';
const suffix = '["payload"]';
const backing = new Uint8Array([10, 20, 30, 40]);
const view = backing.subarray(1, 3);
let getters = 0;
for (const key of ['buffer', 'byteLength', 'byteOffset', 'length', Symbol.iterator, Symbol.toStringTag]) {
  Object.defineProperty(view, key, {get() { getters++; throw new Error('byte getter'); }});
}
assert.equal(kind(view), 4);
const first = copy(view, context, suffix);
const second = copy(view, context, suffix);
assert.deepEqual([...first], [20, 30]);
assert.deepEqual([...second], [20, 30]);
assert.notEqual(first.buffer, second.buffer);
assert.notEqual(first.buffer, backing.buffer);
first[0] = 99;
backing[2] = 88;
assert.deepEqual([...second], [20, 30]);
assert.equal(getters, 0);
const buffer = Buffer.from([0, 1, 2, 3]).subarray(1, 3);
assert.equal(kind(buffer), 4);
assert.deepEqual([...copy(buffer, context, suffix)], [1, 2]);
const foreign = vm.runInNewContext('new Uint8Array([4,5,6]).subarray(1)');
assert.equal(kind(foreign), 4);
assert.deepEqual([...copy(foreign, context, suffix)], [5, 6]);
assert.deepEqual([...copy(new Uint8Array(0), context, suffix)], []);
const lazy = {toString() { throw new Error('context formatted on success'); }};
assert.deepEqual([...copy(buffer, lazy, lazy)], [1, 2]);
for (const value of [undefined, null, [], new ArrayBuffer(2), new DataView(new ArrayBuffer(2)), new Int8Array(2)]) {
  assert.notEqual(kind(value), 4);
}
const detached = new Uint8Array([7, 8]);
structuredClone(detached.buffer, {transfer: [detached.buffer]});
assert.equal(kind(detached), 4);
assert.throws(() => copy(detached, context, suffix), error =>
  error instanceof TypeError && error.message.startsWith('parameter packets[1]["payload"]: ') &&
  error.message.split('parameter packets[1]["payload"]').length === 2);

const reflection = new TypeError('original reflection');
const proxy = new Proxy({payload: buffer}, {getOwnPropertyDescriptor() {throw reflection;}});
assert.throws(() => snapshotRecord(proxy, ['payload'], context), error => error === reflection);
const originalApply = Reflect.apply;
try {
  Reflect.apply = () => {throw reflection;};
  assert.throws(() => kind(buffer), error => error === reflection);
} finally {
  Reflect.apply = originalApply;
}
const originalCopy = napi.copyBytes;
try {
  for (const original of [new RangeError('range'), new Error('JS'), Symbol('JS'), {original: true}]) {
    napi.copyBytes = () => {throw original;};
    assert.throws(() => copy(buffer, context, suffix), error => error === original);
  }
  const original = new TypeError('owned copy');
  napi.copyBytes = () => {throw original;};
  assert.throws(() => copy(buffer, context, suffix), error =>
    error instanceof TypeError && error !== original &&
    error.message === 'parameter packets[1]["payload"]: owned copy');
  const diagnosticFailure = {message: 'copy diagnostic failed'};
  for (const descriptor of [
    {get() {throw diagnosticFailure;}},
    {value: {toString() {throw diagnosticFailure;}}},
  ]) {
    const copyError = new TypeError('original copy failure');
    Object.defineProperty(copyError, 'message', descriptor);
    napi.copyBytes = () => {throw copyError;};
    assert.throws(() => copy(buffer, context, suffix), error => error === copyError);
  }
} finally {
  napi.copyBytes = originalCopy;
}
assert.deepEqual([...copy(buffer, context, suffix)], [1, 2]);
console.log('host byte copies passed');
''';
