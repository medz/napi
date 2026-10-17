/// Both backends consume a declared Future callback with the same captured
/// intrinsics. This observes the callback's input Promise, never its caller's
/// public output Promise.
const callbackPromisePolicy = r'''
import {types as $napiCallbackTypes} from 'node:util';
const $napiCallbackIsPromise = $napiCallbackTypes.isPromise;
const $napiCallbackApply = Reflect.apply;
const $napiCallbackThen = globalThis.Promise.prototype.then;
const $napiCallbackQueueMicrotask = globalThis.queueMicrotask;
function $napiObserveCallbackPromise(value, fulfill, reject) {
  if (!$napiCallbackIsPromise(value)) throw new TypeError('callback result: expected a Promise');
  function deliver(handler, value) {
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
