# Stream exports

Both targets map a non-nullable Dart `Stream<T>` to a JavaScript
`AsyncIterableIterator<T, undefined, undefined>`. Synchronous factories and
`async*` declarations use the ordinary annotation or external selection:

```dart
@NAPI()
Stream<int> count(int limit) async* {
  for (var i = 0; i < limit; i++) {
    yield i;
  }
}
```

```js
import {count} from '@scope/example';
for await (const value of count(3)) {
  console.log(value);
}
```

Methods, getters, static methods and ordinary generic payloads use the same
mapping. `Stream<void>` yields `undefined`. Streams are not inputs; nullable
outer streams, nested streams, `Future<Stream<T>>`, `Stream<Future<T>>`, callback
stream signatures and `sync* Iterable<T>` are rejected at build time. Opaque
generic payloads can contain a JavaScript Promise without changing the Dart
signature to `Stream<Future<T>>`.

## Subscription and demand

Input validation, input snapshots and the Dart factory run synchronously during
the export call. Their errors throw synchronously. The first `next()` starts one
subscription; an unused iterator or `return()` before the first read never
listens. An iterator returns itself from `[Symbol.asyncIterator]()`.

Each `next()` returns a genuine Promise. Concurrent reads receive events in FIFO
order. Single-subscription sources pause when there are no waiting reads and
resume for demand. Broadcast sources stay subscribed; each exported iterator is
independent. Listening to an already used single-subscription source rejects the
new iterator's first read with the source's error.

An adapter holds at most **64 undelivered items**. Overflow cancels its
subscription once and records a JavaScript `RangeError`; it never silently drops
an event. This also bounds items from a source that ignores pause. The cap counts
items, not their bytes, and does not bound a source's own internal buffers.

## Values and errors

Every admitted event completes the ordinary output validation and conversion
before entering the queue. Structural values become host snapshots at that
point, while opaque payloads and selected references preserve identity. Later
Dart mutation cannot alter an admitted List, Map, record or value-class snapshot.
The queue owns a private envelope, so `null` and `undefined` remain distinct.

Read Promises resolve with a null-prototype `{value, done}` object. The item is
not a Promise resolution target: a callable `then`, a getter named `then` or an
actual Promise inside `value` is never assimilated by the binding. Types use `T`,
not `Awaited<T>`. This differs from a root [Future result](futures.md), which
follows standard Promise resolution.

The first source, conversion or overflow failure terminates admission and starts
cancellation immediately. Already admitted values are delivered first, then one
read rejects with the original error. Later reads finish with
`{value: undefined, done: true}`. Ordinary Dart errors retain the shared error
conversion; captured JavaScript exceptions retain their exact value, including
`null` and `undefined`. Natural completion drains the queue before reporting done.

## Return and resource cleanup

`return()` marks the iterator closing before calling Dart cancellation. It drops
unpaired queue entries, waits for cancellation and previously accepted host
delivery acknowledgements, and then resolves to the done result. Repeated returns
share one cancellation operation. If cancellation fails, each return rejects
with that cancellation error. A source error remains the first read error even
if cancellation subsequently fails.

A stream retains the original call's receiver, inputs and deduplicated
[resource operation leases](resources.md). It never acquires a new lease merely
because an output is a resource, and discarding an output never invokes its
business cleanup. Closing any leased owner cancels the stream, waits for
cancellation and accepted host deliveries, then releases its leases. Business
cleanup runs once. Its error has priority; if cleanup succeeds, the first stream
cancellation error in registration order rejects the owner's close Promise.
Factory, listen and cancellation reentry cannot bypass those leases.

An explicit [AbortSignal input](cancellation.md) also connects to the owned
subscription. Abort shares the return/close cancellation path, discards unpaired
items and rejects one read with its exact reason after cancellation and earlier
delivery acknowledgements. Earlier terminal states retain their outcome.

The facade and pending deliveries own their state without a permanent strong
stream registry. Completed streams release retained inputs. Dropping an iterator
does not promise deterministic cancellation or arbitrary cross-heap cycle
collection. Authors should finish iteration, use `return()`/`for await` early
exit, or close the resource. Worker/environment teardown drops bridge references;
finalizers never execute JavaScript or business cancellation in a dead realm.

## Backend implementation

The shared Dart kernel owns subscription state, FIFO admission and cancellation.
Wasm carries event envelopes as traced host references. Native uses owned host
values and a private reference wrapper with `next` and `return`; it reuses ABI 14,
the existing owner event pump, Future transport and delivery acknowledgement.
There is no additional C event queue or VM build requirement. Native snapshots
have per-item host-reference cost; the 64-item limit is not a zero-allocation or
byte-budget claim.

The implementation targets the pinned Dart 3.13.5 compiler/runtime. Verification
uses fresh annotation and external-selection npm packages after deleting their
source/build projects, Node 24.19.0 and 26.11.1, and TypeScript 7.0.2 with NodeNext
and Bundler resolution, both optional-property modes and both function-variance
modes. Native remains experimental and qualified only for macOS arm64; the
WasmGC SDK adapter and native runtime coupling are described in
[the architecture](architecture.md) and [native builds](native.md).
