/// Both backends use the same weak source ownership and native signal policy.
/// The target is a Wasm WeakRef or a native owner-local weak target number.
const cancellationPolicy = r'''
import {addAbortListener as $napiAddAbortListener} from 'node:events';
import {types as $napiSignalTypes} from 'node:util';
const $napiSignalApply = Reflect.apply;
const $napiSignalAborted = Object.getOwnPropertyDescriptor(AbortSignal.prototype, 'aborted').get;
const $napiSignalReason = Object.getOwnPropertyDescriptor(AbortSignal.prototype, 'reason').get;
const $napiSignalRemove = EventTarget.prototype.removeEventListener;
const $napiSignalIsProxy = $napiSignalTypes.isProxy;
const $napiSignalWeakRef = WeakRef;
const $napiSignalDeref = WeakRef.prototype.deref;
const $napiSignalQueue = queueMicrotask;
const $napiSignalTypeError = TypeError;
const $napiSignalRegister = FinalizationRegistry.prototype.register;
const $napiSignalUnregister = FinalizationRegistry.prototype.unregister;
const $napiSignalFinalizer = new FinalizationRegistry(({source, listener}) => {
  const signal = $napiSignalApply($napiSignalDeref, source, []);
  if (signal !== undefined) $napiSignalApply($napiSignalRemove, signal, ['abort', listener]);
});
function $napiCheckAbortSignal(value, nullable, path) {
  if (value === null && nullable) return null;
  if (value === null || typeof value !== 'object' || $napiSignalIsProxy(value)) {
    throw new $napiSignalTypeError(path + ': expected AbortSignal' + (nullable ? ' or null' : ''));
  }
  $napiSignalApply($napiSignalAborted, value, []);
  return value;
}
// These factories capture only a weak companion, never the original signal or
// a Dart token. A finalizer must not hold Node's source-owning disposable.
function $napiQueueSignal(weak, rearm) {
  $napiSignalQueue(() => {
    const companion = $napiSignalApply($napiSignalDeref, weak, []);
    if (companion === undefined || companion.target === null) return;
    if (rearm) companion.arm(companion.target);
    else {
      const target = companion.target;
      companion.target = null;
      companion.notify(target);
    }
  });
}
function $napiSignalListener(weak) {
  return () => {
    const companion = $napiSignalApply($napiSignalDeref, weak, []);
    if (companion === undefined) return;
    companion.stopListening();
    // A manually dispatched abort event consumes Node's once listener without
    // changing aborted. Rearm on a microtask, checking for a real abort in gap.
    $napiQueueSignal(weak, !companion.aborted());
  };
}
class $napiSignalCompanion {
  signal;
  notify;
  target = null;
  listener = null;
  adapter;
  constructor(signal, notify) {
    this.signal = signal;
    this.notify = notify;
  }
  aborted() { return $napiSignalApply($napiSignalAborted, this.signal, []); }
  reason() { return $napiSignalApply($napiSignalReason, this.signal, []); }
  arm(target) {
    this.target = target;
    if (this.listener !== null) return;
    const weak = new $napiSignalWeakRef(this);
    if (this.aborted()) { $napiQueueSignal(weak, false); return; }
    const listener = $napiSignalListener(weak);
    this.listener = listener;
    try {
      $napiAddAbortListener(this.signal, listener);
      $napiSignalApply($napiSignalRegister, $napiSignalFinalizer,
          [this, {source: new $napiSignalWeakRef(this.signal), listener}, this]);
    } catch (error) { this.detach(); throw error; }
    if (this.aborted()) { this.stopListening(); $napiQueueSignal(weak, false); }
  }
  stopListening() {
    const listener = this.listener;
    this.listener = null;
    $napiSignalApply($napiSignalUnregister, $napiSignalFinalizer, [this]);
    if (listener !== null) $napiSignalApply($napiSignalRemove, this.signal, ['abort', listener]);
  }
  detach() { this.target = null; this.stopListening(); }
}
function $napiCreateSignalCompanion(signal, notify) {
  return new $napiSignalCompanion($napiCheckAbortSignal(signal, false, 'AbortSignal'), notify);
}
''';

/// Per-notify identity keeps multiple instances independent without a strong
/// registry. The Wasm token owns its companion directly through an externref.
const wasmCancellationPolicy = r'''
const signalOwners = new WeakMap();
const signalWeakMap = WeakMap;
const signalWeakMapGet = WeakMap.prototype.get;
const signalWeakMapSet = WeakMap.prototype.set;
export const checkAbortSignal = $napiCheckAbortSignal;
export function prepareAbortSignal(value, nullable, path, notify) {
  const signal = $napiCheckAbortSignal(value, nullable, path);
  return signal === null ? null : readAbortSignal(signal, notify);
}
function signalNotifier(notify) {
  return weak => {
    const token = $napiSignalApply($napiSignalDeref, weak, []);
    if (token !== undefined) notify(token);
  };
}
export function readAbortSignal(signal, notify) {
  let signals = $napiSignalApply(signalWeakMapGet, signalOwners, [notify]);
  if (signals === undefined) {
    signals = new signalWeakMap();
    $napiSignalApply(signalWeakMapSet, signalOwners, [notify, signals]);
  }
  const weak = $napiSignalApply(signalWeakMapGet, signals, [signal]);
  let companion = weak === undefined ? undefined : $napiSignalApply($napiSignalDeref, weak, []);
  if (companion === undefined) {
    companion = $napiCreateSignalCompanion(signal, signalNotifier(notify));
    $napiSignalApply(signalWeakMapSet, signals, [signal, new $napiSignalWeakRef(companion)]);
  }
  return companion;
}
export function abortSignalTarget(companion) {
  return companion.adapter === undefined ? null : $napiSignalApply($napiSignalDeref, companion.adapter, []) ?? null;
}
export function bindAbortSignal(companion, target) {
  // A companion can outlive its weak token during a host call. A replacement
  // token has no registrations and must not inherit the old host listener.
  companion.detach();
  companion.adapter = new $napiSignalWeakRef(target);
}
export function abortSignalAborted(companion) { return companion.aborted() ? 1 : 0; }
export function abortSignalReason(companion) { return {threw: true, value: companion.reason()}; }
export function armAbortSignal(companion) {
  try { companion.arm(companion.adapter); return null; }
  catch (value) { return {threw: true, value}; }
}
export function detachAbortSignal(companion) { companion.detach(); }
''';
