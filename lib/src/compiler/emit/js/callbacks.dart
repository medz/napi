/// Both backends consume a declared Future callback with the same captured
/// intrinsics. This observes the callback's input Promise, never its caller's
/// public output Promise.
const callbackPromisePolicy =
    _nodeCallbackPromiseBrands +
    _callbackPromiseStart +
    _nodeCallbackPromiseCheck +
    _callbackPromiseEnd;
const browserCallbackPromisePolicy =
    '\n$_callbackPromiseStart$_callbackPromiseEnd';

const _nodeCallbackPromiseBrands = r'''
import {types as $napiCallbackTypes} from 'node:util';
const $napiCallbackIsPromise = $napiCallbackTypes.isPromise;
''';

const _callbackPromiseStart = r'''const $napiCallbackApply = Reflect.apply;
const $napiCallbackThen = globalThis.Promise.prototype.then;
const $napiCallbackQueueMicrotask = globalThis.queueMicrotask;
function $napiObserveCallbackPromise(value, fulfill, reject) {
''';

const _nodeCallbackPromiseCheck = r'''  if (!$napiCallbackIsPromise(value)) throw new TypeError('callback result: expected a Promise');
''';

const _callbackPromiseEnd = r'''  function deliver(handler, value) {
    try { handler(value); }
    catch (error) { $napiCallbackQueueMicrotask(() => { throw error; }); }
  }
  // Ignore an own then override. Intrinsic constructor/species errors propagate
  // synchronously to the calling bridge with the exact thrown value.
  $napiCallbackApply($napiCallbackThen, value, [
    value => { deliver(fulfill, value); },
    error => { deliver(reject, error); },
  ]);
}
''';

/// The control and its envelopes remain private to the generated transports.
const callbackStreamPolicy = r'''
const $napiCallbackAsyncIterator = Symbol.asyncIterator;
function $napiOpenCallbackStream(value) {
  const object = value => value !== null && (typeof value === 'object' || typeof value === 'function');
  if (!object(value)) throw new TypeError('callback result: expected an async iterator');
  const iterate = value[$napiCallbackAsyncIterator];
  if (typeof iterate !== 'function') throw new TypeError('callback result: expected an async iterator');
  let iterator = $napiCallbackApply(iterate, value, []);
  if (!object(iterator)) throw new TypeError('callback result: invalid async iterator');
  let next = iterator.next;
  if (typeof next !== 'function') throw new TypeError('callback result: expected iterator.next');
  let closed = false;
  return async function advance(cancel) {
    if (closed) return {__proto__: null, done: true};
    if (cancel) {
      closed = true;
      const current = iterator;
      iterator = next = null;
      const finish = current.return;
      if (finish == null) return {__proto__: null, done: true};
      if (typeof finish !== 'function') throw new TypeError('callback result: expected iterator.return');
      const result = await $napiCallbackApply(finish, current, []);
      if (!object(result)) throw new TypeError('callback result: invalid iterator return result');
      return {__proto__: null, done: true};
    }
    const result = await $napiCallbackApply(next, iterator, []);
    if (closed) return {__proto__: null, done: true};
    if (!object(result)) throw new TypeError('callback result: invalid iterator next result');
    if (result.done) {
      closed = true;
      iterator = next = null;
      return {__proto__: null, done: true};
    }
    return {__proto__: null, done: false, value: result.value};
  };
}
''';
