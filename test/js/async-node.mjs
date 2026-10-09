import assert from 'node:assert/strict';
import { setImmediate as immediate } from 'node:timers/promises';
import { runInNewContext } from 'node:vm';
import * as api from '@napi/async';
import * as subpath from '@napi/async/module.wasm';
import * as relative from './dist/module.wasm';
import { asyncInt } from './dist/module.wasm';

const publicNames = [
  'asyncBool', 'asyncInt', 'asyncDouble', 'asyncString', 'asyncBytes',
  'nullableBool', 'nullableInt', 'nullableDouble', 'nullableString',
  'nullableBytes', 'asyncVoid', 'throwBeforeFuture', 'asyncFailure',
  'oversizedResult', 'nullableOversizedResult', 'completerSync',
  'microtaskOrder', 'delayedValue', 'canceledTimer', 'retainBytes',
  'readRetainedBytes', 'freshBytes', 'javascriptFailure',
  'badErrorFormatter', 'badStackFormatter', 'syncBadErrorFormatter',
  'countedAdd', 'calls',
];
for (const name of publicNames) {
  assert.equal(typeof api[name], 'function', `${name} is a named Wasm export`);
  assert.equal(api[name], subpath[name], `${name} package subpath shares its instance`);
  assert.equal(api[name], relative[name], `${name} relative import shares its instance`);
  assert.match(Function.prototype.toString.call(api[name]), /\[native code\]/,
    `${name} is a raw Wasm function`);
}
assert.equal(asyncInt, api.asyncInt);

let checks = 0;
function invoke(name, ...args) {
  let promise;
  assert.doesNotThrow(() => { promise = api[name](...args); },
    `${name} must return a Promise even when its arguments are invalid`);
  assert.ok(promise instanceof Promise, `${name} must return a real Promise`);
  checks++;
  return promise;
}
async function bounded(promise) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('Promise did not settle')), 3000);
      }),
    ]);
  } finally {
    clearTimeout(timer);
  }
}
async function rejection(name, args, errorType, message, parameter) {
  await assert.rejects(bounded(invoke(name, ...args)), (error) => {
    assert.ok(error instanceof errorType, `${name} rejected with ${error?.constructor?.name}`);
    if (message) assert.match(error.message, message);
    if (parameter) {
      const context = `parameter ${parameter}:`;
      assert.equal(error.message.split(context).length - 1, 1, `${name}: ${context} must occur exactly once`);
    } else {
      assert.equal(error.message.includes('parameter '), false, `${name}: result and business errors have no argument context`);
    }
    return true;
  });
}

const unhandled = [];
const onUnhandled = (error) => unhandled.push(error);
process.on('unhandledRejection', onUnhandled);
process.on('uncaughtException', onUnhandled);
try {
  assert.equal(await invoke('asyncBool', true), true);
  assert.equal(await invoke('asyncBool', false), false);
  for (const value of [0, 42, -42, Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER]) {
    assert.equal(await invoke('asyncInt', value), value);
  }
  for (const value of [0, -0, 0.125, NaN, Infinity, -Infinity]) {
    assert.ok(Object.is(await invoke('asyncDouble', value), value));
  }
  for (const value of ['', '你好🚀', 'a\0b', '\ud800', '\udfff', '\ud800x\udfff']) {
    const result = await invoke('asyncString', value);
    assert.equal(result, value);
    assert.equal(result.length, value.length);
  }
  assert.equal(await invoke('asyncVoid'), undefined);
  assert.equal(await invoke('asyncInt', 7, 'ignored native Wasm extra argument'), 7);

  const nullableValues = [
    ['nullableBool', true],
    ['nullableInt', Number.MAX_SAFE_INTEGER],
    ['nullableDouble', -Infinity],
    ['nullableString', 'nullable\0\ud800'],
    ['nullableBytes', new Uint8Array([0, 128, 255])],
  ];
  for (const [name, value] of nullableValues) {
    assert.equal(await invoke(name, null), null);
    assert.deepEqual(await invoke(name, value), value);
    await rejection(name, [undefined], TypeError, null, 'value');
    await rejection(name, [], TypeError, null, 'value');
  }
  assert.ok(Number.isNaN(await invoke('nullableDouble', NaN)));
  assert.ok(Object.is(await invoke('nullableDouble', -0), -0));

  const invalid = [
    ['asyncBool', [1]], ['asyncInt', [1n]], ['asyncInt', [1.5]],
    ['asyncInt', [NaN]], ['asyncInt', [Infinity]], ['asyncDouble', ['1']],
    ['asyncString', [null]], ['asyncString', [new String('boxed')]],
    ['asyncBytes', [[1, 2]]], ['asyncBytes', [new Uint16Array([1, 2])]],
    ['asyncBytes', [new DataView(new ArrayBuffer(2))]],
    ['asyncInt', []], ['asyncBool', [undefined]], ['asyncDouble', [null]],
    ['asyncInt', [Promise.resolve(1)]], ['asyncString', [Symbol('text')]],
  ];
  for (const [name, args] of invalid) await rejection(name, args, TypeError, null, 'value');
  for (const name of ['asyncBool', 'asyncInt', 'asyncDouble', 'asyncString', 'asyncBytes']) {
    await rejection(name, [], TypeError, null, 'value');
  }
  await rejection('asyncInt', [Number.MAX_SAFE_INTEGER + 1], RangeError, null, 'value');
  await rejection('asyncInt', [Number.MIN_SAFE_INTEGER - 1], RangeError, null, 'value');
  await rejection('nullableInt', [Number.MAX_SAFE_INTEGER + 1], RangeError, null, 'value');
  for (const [args, parameter] of [
    [['1', 2], 'a'], [[1, '2'], 'b'], [['1', '2'], 'a'], [[], 'a'], [[1], 'b'],
  ]) {
    const before = api.calls();
    await rejection('countedAdd', args, TypeError, /Expected a number/, parameter);
    assert.equal(api.calls(), before, 'invalid arguments reject before Dart business entry');
  }
  const beforeAdd = api.calls();
  assert.equal(await invoke('countedAdd', 1, 2), 3);
  assert.equal(api.calls(), beforeAdd + 1, 'valid arguments enter async Dart business once');
  await rejection('oversizedResult', [], RangeError);
  await rejection('nullableOversizedResult', [], RangeError);
  await rejection('throwBeforeFuture', ['before Future'], Error, /before Future/);
  await rejection('asyncFailure', [0], TypeError, /argument failure/);
  await rejection('asyncFailure', [1], RangeError, /range failure/);
  await rejection('asyncFailure', [2], Error, /state failure/);

  const byteInput = new Uint8Array([1, 2]);
  const OriginalUint8Array = globalThis.Uint8Array;
  try {
    const copyError = new TypeError('owned copy');
    globalThis.Uint8Array = class { constructor() { throw copyError; } };
    await rejection('asyncBytes', [byteInput], TypeError, /^parameter value: owned copy$/, 'value');
    const diagnosticFailure = { message: 'copy diagnostic failed' };
    for (const descriptor of [
      { get() { throw diagnosticFailure; } },
      { value: { toString() { throw diagnosticFailure; } } },
    ]) {
      const original = new TypeError('original copy failure');
      Object.defineProperty(original, 'message', descriptor);
      globalThis.Uint8Array = class { constructor() { throw original; } };
      await assert.rejects(bounded(invoke('asyncBytes', byteInput)), (error) => error === original);
    }
  } finally {
    globalThis.Uint8Array = OriginalUint8Array;
  }
  assert.deepEqual(await invoke('asyncBytes', byteInput), new Uint8Array([1, 2]), 'byte Promise calls recover after diagnostic failures');

  // An immediate caller mutation or transfer must not affect the owned input.
  const original = new Uint8Array([1, 128, 255]);
  const snapshot = invoke('asyncBytes', original);
  original.fill(9);
  assert.deepEqual(await snapshot, new Uint8Array([1, 128, 255]));
  const backing = new Uint8Array([99, 2, 128, 255, 88]);
  const view = backing.subarray(1, 4);
  const viewSnapshot = invoke('asyncBytes', view);
  backing.fill(9);
  assert.deepEqual(await viewSnapshot, new Uint8Array([2, 128, 255]));
  const transferred = new Uint8Array([3, 128, 255]);
  const transferredSnapshot = invoke('asyncBytes', transferred);
  structuredClone(transferred.buffer, { transfer: [transferred.buffer] });
  assert.equal(transferred.byteLength, 0);
  assert.deepEqual(await transferredSnapshot, new Uint8Array([3, 128, 255]));
  for (const name of ['asyncBytes', 'nullableBytes']) {
    await rejection(name, [transferred], TypeError, null, 'value');
    const outOfBounds = new Uint8Array(new ArrayBuffer(8, { maxByteLength: 16 }), 2, 3);
    outOfBounds.buffer.resize(1);
    await rejection(name, [outOfBounds], TypeError, null, 'value');
  }
  const buffer = Buffer.from([99, 4, 128, 255, 88]).subarray(1, 4);
  const bufferSnapshot = invoke('asyncBytes', buffer);
  buffer.fill(9);
  assert.deepEqual(await bufferSnapshot, new Uint8Array([4, 128, 255]));
  const foreign = runInNewContext('new Uint8Array([5, 128, 255])');
  const foreignSnapshot = invoke('asyncBytes', foreign);
  foreign.fill(9);
  assert.deepEqual(await foreignSnapshot, new Uint8Array([5, 128, 255]));
  const nullableInput = new Uint8Array([6, 128, 255]);
  const nullableSnapshot = invoke('nullableBytes', nullableInput);
  nullableInput.fill(9);
  assert.deepEqual(await nullableSnapshot, new Uint8Array([6, 128, 255]));

  // Re-reading Dart-owned storage detects an output that accidentally shares it.
  const retainedInput = new Uint8Array([7, 128, 255]);
  const retainedPromise = invoke('retainBytes', retainedInput);
  retainedInput.fill(9);
  assert.equal(await retainedPromise, undefined);
  const result = await invoke('readRetainedBytes');
  assert.deepEqual(result, new Uint8Array([7, 128, 255]));
  result.fill(0);
  assert.deepEqual(await invoke('readRetainedBytes'), new Uint8Array([7, 128, 255]));
  const fresh = await invoke('freshBytes');
  assert.deepEqual(fresh, new Uint8Array([0, 128, 255]));
  assert.ok(fresh instanceof Uint8Array);

  assert.equal(await invoke('completerSync', 8), 8);
  assert.equal(await invoke('microtaskOrder'), 'before,scheduled,after');
  assert.equal(await invoke('delayedValue', 9), 9);
  assert.equal(await invoke('canceledTimer'), 0);
  assert.deepEqual(
    await Promise.all(Array.from({ length: 64 }, (_, value) => invoke('delayedValue', value))),
    Array.from({ length: 64 }, (_, value) => value),
  );

  // Errors crossing JS -> Dart Future -> JS retain the original object.
  for (const originalError of [new Error('js error'), new TypeError('js type'), new RangeError('js range')]) {
    originalError.marker = { retained: true };
    globalThis.napiAsyncHook = () => Promise.reject(originalError);
    await assert.rejects(bounded(invoke('javascriptFailure')), (error) => {
      assert.equal(error, originalError);
      assert.equal(error.marker, originalError.marker);
      assert.equal(error.stack, originalError.stack);
      return true;
    });
  }
  const syncJsError = new Error('synchronous JS hook throw');
  globalThis.napiAsyncHook = () => { throw syncJsError; };
  await assert.rejects(bounded(invoke('javascriptFailure')), (error) => error === syncJsError);
  for (const reason of [null, undefined, 'primitive failure', 17, false]) {
    for (const synchronous of [false, true]) {
      globalThis.napiAsyncHook = () => {
        if (synchronous) throw reason;
        return Promise.reject(reason);
      };
      await assert.rejects(bounded(invoke('javascriptFailure')), (error) => {
        if (reason === null || reason === undefined) {
          assert.ok(error instanceof Error);
          assert.match(error.message, /null|undefined/);
          assert.equal(typeof error.dartStack, 'string');
        } else {
          assert.ok(Object.is(error, reason));
        }
        return true;
      });
    }
  }
  globalThis.napiAsyncHook = () => Promise.resolve(null);
  assert.equal(await invoke('javascriptFailure'), undefined);
  delete globalThis.napiAsyncHook;

  // Hostile Dart formatters must reject promptly without orphaning a child Future.
  await rejection('badErrorFormatter', [], Error, /toString failed/);
  await rejection('badStackFormatter', [], Error, /original failure/);
  await assert.rejects(bounded(invoke('badStackFormatter')), (error) => {
    assert.match(error.dartStack, /toString failed/);
    return true;
  });
  await assert.rejects(bounded(invoke('asyncFailure', 2)), (error) => {
    assert.equal(typeof error.dartStack, 'string');
    assert.ok(error.dartStack.length > 0);
    return true;
  });
  assert.throws(() => api.syncBadErrorFormatter(), (error) => {
    assert.ok(error instanceof Error);
    assert.match(error.message, /toString failed/);
    assert.equal(typeof error.dartStack, 'string');
    assert.ok(error.dartStack.length > 0);
    return true;
  });
  for (let i = 0; i < 16; i++) {
    await rejection('asyncFailure', [2], Error);
    assert.equal(await invoke('asyncInt', i), i);
  }

  // Equal warmup and measured workloads tolerate Wasm's allocation high-water mark.
  async function batch() {
    for (let start = 0; start < 256; start += 32) {
      const pending = Array.from({ length: 32 }, (_, offset) => {
        const input = new Uint8Array(4096);
        input[0] = (start + offset) & 255;
        return invoke('asyncBytes', input).then((output) => {
          assert.equal(output.length, 4096);
          assert.equal(output[0], (start + offset) & 255);
        });
      });
      await Promise.all(pending);
    }
  }
  await batch();
  global.gc();
  const before = process.memoryUsage();
  await batch();
  await immediate();
  global.gc();
  const after = process.memoryUsage();
  const retained = {
    heapUsed: after.heapUsed - before.heapUsed,
    arrayBuffers: after.arrayBuffers - before.arrayBuffers,
  };
  assert.ok(retained.heapUsed < 16 * 1024 * 1024, `host heap grew after warmup: ${retained.heapUsed}`);
  assert.ok(retained.arrayBuffers < 16 * 1024 * 1024, `array buffers grew after warmup: ${retained.arrayBuffers}`);
  await immediate();
  await immediate();
  assert.deepEqual(unhandled, [], 'rejected exports must not leak unhandled async errors');
  console.log(JSON.stringify({ checks, nativeFunctions: publicNames.length, retained }));
} finally {
  process.removeListener('unhandledRejection', onUnhandled);
  process.removeListener('uncaughtException', onUnhandled);
  delete globalThis.napiAsyncHook;
}
