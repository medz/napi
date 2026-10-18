# Future exports

A selected Dart function, method or getter returning `Future<T>` exposes a
genuine JavaScript Promise on both backends. Its fulfillment value follows
standard Promise resolution of the converted result. This also applies to synchronous Dart
functions returning an existing Future and to aliases of `dart:async/Future`.
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
business Future has no external owner and the caller drops the public Promise. Temporary native callback handles never survive their
scope. Dropping the JavaScript Promise does not cancel Dart work.

Native completion uses the owning Node thread and its Dart isolate. The private
bridge creates the Promise outside Dart, queues converted results, exits Dart
before calling JavaScript resolvers, and acknowledges release of retained Dart
values afterwards. An unresolved Completer alone does not keep Node alive; live
Dart timers and ports do. Worker/environment teardown discards pending
capabilities and shuts down its isolate without invoking JS in a dead realm.

Wasm completion uses the pinned Dart SDK's host scheduling. Its private
capability keeps explicit roots until conversion and resolver delivery finish.
Both targets run business code in Dart; Promise return types do not imply
background-thread execution. Ordering against unrelated JavaScript microtasks
is not guaranteed to be identical between the two runtimes.

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

## Remaining contracts

Future/Promise inputs, `FutureOr`, nullable outer Futures, nested Future payloads,
`async void`, synchronous generators and still-unsupported payload types produce
build diagnostics. `async* Stream<T>` uses the separate [stream adapter](streams.md).
[Callbacks](callbacks.md) and [explicit cancellation](cancellation.md) have their
own contracts. An AbortSignal input never settles a business Future early.
[SharedBytes](shared-bytes.md) has a separate checked-view ownership contract;
ordinary byte snapshots are not shared implicitly.

## Validation scope

The generated contract was tested on Dart 3.13.5 and Node 24.19.0/26.11.1,
with TypeScript 7.0.2 in NodeNext and Bundler modes. Native execution uses the
experimental macOS arm64 runtime bundle, private ABI 15 (57 slots), pinned to
Dart revision `04bcd1036cdc799ac6564988f159ee454d42c822`. Wasm uses the matching
SDK's version-specific compiler/host adapter; this is not a portable WASI ABI.

`dart run tool/future_fixture.dart [native-runtime-bundle]` builds an independent
Dart consumer through the public package API, packs npm artifacts, deletes the
original business/build sources and installs offline into a relocated path with
spaces and Unicode characters. The shared suite covers normal and adversarial
completion, concurrent calls, independent module instances, pending argument
and receiver reachability, event-loop liveness, unhandled rejections, and normal
or terminated Workers in eleven fresh-process scenarios. The full Wasm and native
verification commands include this fixture. These tests establish the ordinary
Future delivery contract above. The separate [resource fixture](resources.md)
checks generated cleanup and operation leases. The generic payload fixture adds
standard thenable adoption, exact getter/rejection values, nullable and undefined
completion, selected `then` members, and preservation of synchronous/nested values.

The standard-resolution update passed the complete native/Wasm suites on both
Node versions, 528 Dart tests (one Windows-only skip locally), and 23 Wasm
resource-kernel tests. The opaque suite now has 13 fresh-process scenarios and
eight TypeScript configurations per backend/version. The resource suite has 26
scenarios, including nine opaque-result resolve/reject/getter-throw combinations
that keep cleanup pending through GC and thenable settlement. That update reused
ABI13; its runtime binaries and settlement implementation did not change.

## Measured update cost

The unchanged Future fixture was compared with its prior installed Wasm package
using two A/A and three balanced A/B ABBA blocks per Node version (40 independent
processes). Each sample excludes import and 10,000 warmup calls, then checks
100,000 sequential awaits and 100,000 calls in batches of 128. Median changes
were -0.42% / -1.17% on Node 24 and -2.19% / -4.04% on Node 26. A/A median
movement was -0.13% to +2.54%; no repeatable slowdown appeared, and these samples
do not establish a general speedup or application-throughput bound.

The nine-file fixture grows from 549,966 to 637,976 bytes (+88,010). Of this,
85,890 bytes are Wasm name metadata; executable code grows 1,434 bytes and all
non-name core data grows 1,587 bytes. Actual npm archives grow 2,738 and 2,609
bytes on the two builds. The wrapper Wasm, calls, host, reference bindings,
package metadata and license remain byte-identical. No artifact was stripped
for this comparison; native artifact sizes were not measured in this update.
