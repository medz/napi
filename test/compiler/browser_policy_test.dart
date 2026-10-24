import 'dart:convert';
import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/js/boundary.dart';
import 'package:napi/src/compiler/emit/js/callbacks.dart';
import 'package:napi/src/compiler/emit/js/references.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:test/test.dart';

import '../support/process.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-browser-policy-');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<void> run(String source) async {
    final script = File('${directory.path}/check.mjs');
    await script.writeAsString(source);
    await runProcess(Platform.environment['NODE'] ?? 'node', [
      script.path,
    ], timeout: const Duration(seconds: 20));
  }

  test('browser policies preserve supported values in mixed modules', () async {
    final input = File('${directory.path}/business.dart');
    await input.writeAsString('''
import 'dart:typed_data';
import 'package:napi/napi.dart';
@NAPI() Uint8List bytes(Uint8List value) => value;
@NAPI() ByteBuffer buffer(ByteBuffer value) => value;
@NAPI() SharedBytes shared(SharedBytes value) => value;
@NAPI() JsMap<String, int> map(JsMap<String, int> value) => value;
@NAPI() JsArray<int>? array(JsArray<int>? value) => value;
@NAPI() List<int> list(List<int> value) => value;
@NAPI() Map<String, int> copiedMap(Map<String, int> value) => value;
@NAPI() bool signal(AbortSignal value) => value.aborted;
@NAPI() Future<int> callback(Future<int> Function() value) => value();
@NAPI() class Counter { Counter(); int get value => 1; }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource { Resource(); void close() {} }
@NAPI() List<Counter> counters(List<Counter> value) => value;
@NAPI() List<Resource> resources(List<Resource> value) => value;
''');
    final plan = lower(
      validate(
        await AnnotationFrontend(
          packagesPath: File('.dart_tool/package_config.json').absolute.path,
        ).read(input.uri),
      ),
    );
    final source = emitBoundary(plan, browser: true);
    expect(source, isNot(contains('node:')));
    expect(source, contains("from './browser-references.mjs'"));
    expect(emitBoundary(plan), emitBoundary(plan, browser: false));
    expect(emitBoundary(plan), contains("from 'node:v8'"));
    expect(emitBoundary(plan), contains("from 'node:util'"));
    await File('${directory.path}/boundary.mjs').writeAsString(source);
    await File('${directory.path}/browser-references.mjs')
        .writeAsString(emitReferences());
    final contexts = {
      for (final call in plan.functions)
        call.binding.exportName: call.inputContexts.single,
    };
    final counter = plan.classes.indexWhere(
      (value) => value.binding.exportName == 'Counter',
    );
    await run(
      'const contexts = ${jsonEncode(contexts)};\n'
      'const counterId = $counter;\n'
      r'''
import assert from 'node:assert/strict';
import {runInNewContext} from 'node:vm';
import * as host from './boundary.mjs';
import {registerReference} from './browser-references.mjs';
const read = (name, value) => host.readValue(value, contexts[name]);
const foreign = runInNewContext('new Uint8Array([1, 2, 3]).subarray(1)');
const copied = read('bytes', foreign);
assert.deepEqual([...copied], [2, 3]);
assert.notEqual(copied.buffer, foreign.buffer);
assert.deepEqual([...new Uint8Array(read('buffer', foreign.buffer))], [1, 2, 3]);
assert.equal(read('shared', foreign), foreign);
let traps = 0;
const handler = {get() { traps++; throw 'proxy'; }, getPrototypeOf() { traps++; throw 'proxy'; }};
for (const name of ['bytes', 'shared']) {
  assert.throws(() => read(name, new Proxy(foreign, handler)), TypeError);
  assert.throws(() => read(name, new Uint8ClampedArray(2)), TypeError);
  assert.throws(() => read(name, new Uint8Array(new SharedArrayBuffer(2))), TypeError);
}
assert.throws(() => read('buffer', new Proxy(foreign.buffer, handler)), TypeError);
assert.throws(() => read('buffer', new SharedArrayBuffer(2)), TypeError);
assert.equal(traps, 0);
Object.defineProperty(foreign, Symbol.toStringTag, {get() { throw Error('own tag'); }});
assert.deepEqual([...read('bytes', foreign)], [2, 3]);
const raw = new ArrayBuffer(2), view = new Uint8Array(raw);
structuredClone(raw, {transfer: [raw]});
assert.throws(() => read('bytes', view), /detached or out-of-bounds/);
assert.throws(() => read('buffer', raw), /detached or out-of-bounds/);
const map = runInNewContext('new Map([["answer", 42]])');
assert.equal(read('map', map), map);
assert.throws(() => read('map', new Proxy(map, handler)), TypeError);
assert.equal(traps, 0);
for (const value of [[], new Proxy([], handler), null]) {
  assert.throws(() => read('array', value), /JsArray is not supported by browser bindings/);
}
assert.equal(traps, 0);
assert.deepEqual(read('list', [2, 3]), [2, 3]);
assert.deepEqual(read('copiedMap', new Map([['answer', 42]])), ['answer', 42]);
registerReference(counterId, value => value, value => value);
const counter = {};
assert.deepEqual(read('counters', [counter]), [counter]);
assert.throws(() => read('resources', [{}]), /Resource policies are not supported by browser bindings/);
let released = 0;
const capability = host.createPromise();
host.attachResourceOperation(capability, () => released++, () => {});
host.activateResourceOperation(capability, 0);
host.completePromise(capability, () => host.resolvePromiseValue(capability, 42));
assert.equal(await capability.promise, 42);
assert.equal(released, 1);
assert.throws(() => host.activateResourceOperation(host.createPromise(), 1), /Resource policies are not supported by browser bindings/);
const controller = new AbortController();
controller.signal.addEventListener('abort', event => event.stopImmediatePropagation());
let calls = 0;
const companion = host.readAbortSignal(controller.signal, () => calls++);
const token = {};
host.bindAbortSignal(companion, token);
assert.equal(host.armAbortSignal(companion), null);
controller.signal.dispatchEvent(new Event('abort'));
await Promise.resolve();
assert.equal(calls, 0);
controller.abort(null);
assert.equal(host.abortSignalAborted(companion), 1);
assert.equal(host.abortSignalReason(companion).value, null);
await Promise.resolve();
assert.equal(calls, 1);
host.detachAbortSignal(companion);
''',
    );
  });

  test('browser callback Promise admission preserves species errors', () async {
    await File('${directory.path}/callback.mjs').writeAsString(
      '$browserCallbackPromisePolicy\n'
      r'export { $napiObserveCallbackPromise as observe };',
    );
    await run(r'''
import assert from 'node:assert/strict';
import {runInNewContext} from 'node:vm';
import {observe} from './callback.mjs';
const values = [];
const failed = error => { throw error; };
const input = Promise.resolve(7);
Object.defineProperty(input, 'then', {get() { throw Error('own then'); }});
observe(input, value => values.push(value), failed);
observe(runInNewContext('Promise.resolve(8)'), value => values.push(value), failed);
let traps = 0;
for (const value of [null, {}, {then() {}}, new Proxy(input, {get() {traps++;}})]) {
  assert.throws(() => observe(value, () => {}, () => {}), TypeError);
}
assert.equal(traps, 0);
for (const error of [new TypeError('species'), null, undefined]) {
  const value = Promise.resolve(9);
  Object.defineProperty(value, 'constructor', {value: {
    get [Symbol.species]() { throw error; },
  }});
  let threw = false;
  try { observe(value, () => {}, () => {}); }
  catch (actual) { threw = true; assert.equal(actual, error); }
  assert(threw);
}
await Promise.resolve();
assert.deepEqual(values, [7, 8]);
''');
  });
}
