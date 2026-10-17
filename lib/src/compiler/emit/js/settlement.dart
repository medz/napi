/// Node's host notification observes final Promise settlement without installing
/// a reaction that would change public unhandled-rejection tracking.
const settlementObserver = r'''
import {promiseHooks as napiPromiseHooks} from 'node:v8';
const napiQueueMicrotask = globalThis.queueMicrotask;
export function createSettlementObserver(release) {
  const pending = new Map();
  let queued = 0;
  let stop = null;
  let disposed = false;
  function stopIfIdle() {
    if (pending.size === 0 && queued === 0 && stop !== null) {
      const disable = stop;
      stop = null;
      disable();
    }
  }
  function settled(promise) {
    const record = pending.get(promise);
    if (record === undefined) return;
    pending.delete(promise);
    queued++;
    // V8 notifies before writing the final Promise state. The queued closure
    // retains the operation after removal from the strong pending registry.
    napiQueueMicrotask(() => {
      try { if (!disposed) release(record.token); }
      finally {
        record.token = null;
        queued--;
        stopIfIdle();
      }
    });
  }
  return {
    observe(promise, token) {
      if (disposed) throw new Error('Promise settlement observer is disposed');
      if (pending.has(promise)) throw new Error('Promise settlement is already observed');
      if (stop === null) stop = napiPromiseHooks.onSettled(settled);
      pending.set(promise, {token});
    },
    dispose() {
      disposed = true;
      pending.clear();
      if (stop !== null) { const disable = stop; stop = null; disable(); }
    },
  };
}
''';
