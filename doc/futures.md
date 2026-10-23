# Future exports

A selected Dart function, method or getter returning `Future<T>` exposes a
genuine JavaScript Promise on both backends. Its fulfillment value follows
standard Promise resolution of the converted result. This also applies to
synchronous Dart functions returning an existing Future and to aliases of
`dart:async/Future`.
The `async` keyword alone does not define the binding contract.

```dart
import 'package:napi/napi.dart';

@NAPI()
Future<int> addLater(int left, [int right = 1]) async => left + right;

@NAPI()
class Counter {
  int value;
  Counter([this.value = 0]);
  Future<int> increment() async => ++value;
}
```

```js
import {addLater, Counter} from '@scope/example';
await addLater(41); // 42
const counter = new Counter();
await counter.increment(); // 1
```

The generated declarations use `Promise<number>` for these results. Existing
scalar, structural, value-class and ordinary reference conversions apply to the
payload. `Future<void>` fulfills with `undefined`; a nullable payload such as
`Future<String?>` can fulfill with `null`. The outer Future itself must be
non-nullable. Constructors and setters remain synchronous.

## Calls and failures

The binding creates a genuine Promise before ordinary receiver, argument or
options validation. Omitted and explicit `undefined` arguments retain the
existing Dart default rules. Conversion and input snapshots run during the call,
followed by the Dart invocation; moving these operations to a later JavaScript
microtask would change observable getters, mutations and defaults.

Invalid inputs, synchronous Dart throws, failed Futures and output-conversion
failures reject the returned Promise. Consumers can consistently use
`await`/`catch` for these failures. Boundary TypeError/RangeError categories and
conversion paths remain intact. JavaScript exceptions from reflection retain
their original value, including thrown `null` or `undefined`. Dart failures
become JavaScript Errors with an own `dartStack` string. Throwing error or stack
formatters use a fixed fallback instead of preventing settlement.

This contract covers ordinary binding operations after Promise creation. It
cannot promise recovery from process termination, allocation failure or a
corrupted Promise constructor. Standard JavaScript invocation rules also apply:
calling a non-constructible export with `new` is not an asynchronous call.

An unobserved rejection remains visible to the host's usual rejection handling.
The binding does not attach a hidden rejection observer to the public Promise.
Each call has independent completion state; repeated returns of the same Dart
Future are separate calls and do not imply the same JavaScript Promise identity.

## Ownership and scheduling

The adapter retains converted arguments and the receiver while the Dart Future
is pending, through result conversion and delivery to the Promise resolver.
Business code does not need to capture these objects in its own Future closure
to keep them reachable. Each module strongly owns pending calls even when a
business Future has no external owner and the caller drops the public Promise.
Dropping the JavaScript Promise does not cancel Dart work.

Promises do not move Dart work to a background thread. Native completion runs
on the owning Node thread. An unresolved Future alone does not keep Node alive;
Dart timers and live ports do. Worker teardown releases pending state without
running cleanup in the terminated environment. Relative ordering with unrelated
JS microtasks can differ between native and Wasm.

## Promise resolution and identity

[Resource bindings](resources.md) acquire operation leases during receiver/input
conversion. For object results, a private Node settlement observer keeps these
leases through the public Promise's eventual settlement, including thenable
adoption. Repeated valid resource cleanup returns the same Promise. Ordinary
argument reachability alone does not provide these disposal guarantees.

A genuine JavaScript Promise assimilates a root result with callable `then`.
It can therefore fulfill with a different value or reject, instead of returning
that original object. Getter side effects and JavaScript mutations of an
existing wrapper can affect this behavior. Nested object fields and collection
elements are not recursively assimilated. The binding does not hide `then`,
box the result or substitute a Promise-like object.

This standard behavior also applies to generic `Future<T>` payloads and selected
generic reference classes with a `then` member. A synchronous opaque return never
reads `then`; a Future hands its raw result to the Promise resolver, which does.
For example, returning `{then(resolve) { resolve(42); }}` from `Future<T>` fulfills
with `42`. Returning that object synchronously, or as a nested element of a
returned container, preserves its identity. `null` and `undefined` remain distinct.

TypeScript declarations describe the resolved value. A private conditional type
handles recursive thenables and union-valued `then` properties: a callable branch
adopts its resolution type, while a non-callable branch preserves the object.
An unknown callable result stays unknown. This does not inspect runtime values or
introduce a consumer wrapper. Mutations outside the declared TypeScript shape,
type assertions and `any` retain TypeScript's usual limitations.

Resolver return is only a resolution handoff for thenables; resource leases wait
for actual settlement. Synchronous and nested identity does not promise the
original object as the fulfillment value of a root thenable.

## Unsupported signatures

Future/Promise inputs, `FutureOr`, nullable outer Futures, nested Future payloads,
`async void`, synchronous generators and still-unsupported payload types produce
build diagnostics. `async* Stream<T>` uses the separate [stream adapter](streams.md).
[Callbacks](callbacks.md) and [explicit cancellation](cancellation.md) have their
own contracts. An AbortSignal input never settles a business Future early.
[SharedBytes](shared-bytes.md) has a separate checked-view ownership contract;
ordinary byte snapshots are not shared implicitly.

## Compatibility

Both backends require the pinned Dart SDK. Wasm uses Dart WasmGC.
See [native requirements](native.md) and
[supported toolchains](../README.md#requirements).
