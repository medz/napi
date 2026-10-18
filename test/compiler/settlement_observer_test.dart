import 'dart:io';

import 'package:napi/src/compiler/emit/js/settlement.dart';
import 'package:test/test.dart';

import '../support/process.dart';

void main() {
  test(
    'settlement observation retains work without handling rejection',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'napi-settlement-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final script = File('${directory.path}/check.mjs');
      await script.writeAsString(
        '''
$settlementObserver
'''
        r'''
import assert from 'node:assert/strict';
import {promiseHooks} from 'node:v8';
const onSettled = promiseHooks.onSettled;
let active = 0, registrations = 0;
promiseHooks.onSettled = callback => {
  active++;
  registrations++;
  const stop = onSettled(callback);
  return () => { active--; stop(); };
};
const tick = () => new Promise(resolve => setImmediate(resolve));
const capability = () => {
  let resolve, reject;
  const promise = new Promise((a, b) => { resolve = a; reject = b; });
  return {promise, resolve, reject};
};
const released = [];
const reentrant = capability();
const observer = createSettlementObserver(token => {
  released.push(token);
  if (token === 'first') {
    observer.observe(reentrant.promise, 'reentrant');
    reentrant.resolve(3);
  }
});
assert.equal(active, 0, 'creation alone installs no hook');
const first = capability(), second = capability();
observer.observe(first.promise, 'first');
observer.observe(second.promise, 'second');
assert.equal(active, 1);
assert.equal(registrations, 1);
first.resolve(1);
assert.deepEqual(released, [], 'release waits until the state write completes');
await tick();
assert.deepEqual(released, ['first', 'reentrant']);
assert.equal(active, 1, 'a pending operation keeps observation active');
let finish;
second.resolve({then(resolve) { resolve({then(accept) { finish = accept; }}); }});
await tick();
assert.deepEqual(released, ['first', 'reentrant']);
finish(2);
await tick();
assert.equal(await second.promise, 2);
assert.deepEqual(released, ['first', 'reentrant', 'second']);
assert.equal(active, 0, 'idle observation stops immediately');

const unhandled = [], handled = [];
process.on('unhandledRejection', (error, promise) => unhandled.push({error, promise}));
process.on('rejectionHandled', promise => handled.push(promise));
for (const error of [new Error('exact'), null, undefined]) {
  const failed = capability();
  observer.observe(failed.promise, error);
  failed.reject(error);
  await tick(); await tick();
  assert.equal(unhandled.at(-1).error, error);
  assert.equal(unhandled.at(-1).promise, failed.promise);
  failed.promise.catch(() => {});
  await tick();
  assert.equal(handled.at(-1), failed.promise);
}
assert.equal(unhandled.length, 3);
assert.equal(handled.length, 3);
assert.equal(active, 0);

let abandoned = capability();
const weak = new WeakRef(abandoned.promise);
observer.observe(abandoned.promise, 'abandoned');
abandoned.resolve({then() {}});
abandoned = null;
for (let i = 0; i < 5; i++) { await tick(); global.gc(); }
assert(weak.deref() instanceof Promise, 'accepted pending work is strongly owned');
const queued = capability();
observer.observe(queued.promise, 'queued-before-dispose');
queued.resolve(4);
const beforeDispose = released.length;
observer.dispose();
observer.dispose();
assert.equal(active, 0);
await tick();
assert.equal(released.length, beforeDispose, 'disposed callbacks never enter a dead runtime');
assert.throws(() => observer.observe(Promise.resolve(), 'late'));
promiseHooks.onSettled = onSettled;
''',
      );
      await runProcess(Platform.environment['NODE'] ?? 'node', [
        '--expose-gc',
        script.path,
      ], timeout: const Duration(seconds: 20));
    },
  );
}
