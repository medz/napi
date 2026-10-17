# Future exports

A selected Dart function, method or getter returning `Future<T>` exposes a
JavaScript `Promise<T>` on both backends. This also applies to synchronous Dart
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

## Remaining contracts

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

Unconditional identity for arbitrary root thenables remains unresolved in
[#129](https://github.com/medz/napi/issues/129): it conflicts with standard Promise
assimilation. Resolver return is only a resolution handoff for thenables; resource
leases now wait for actual settlement. Neither that lifetime guarantee nor
ordinary reference identity establishes unconditional thenable identity.

Future/Promise inputs, `FutureOr`, nullable outer Futures, nested Future payloads,
`async void`, generators and still-unsupported payload types produce build
diagnostics. Callbacks, streams, shared buffers and cancellation have their own
remaining requirements.

## Validation scope

The generated contract was tested on Dart 3.13.5 and Node 24.19.0/26.11.1,
with TypeScript 7.0.2 in NodeNext and Bundler modes. Native execution uses the
experimental macOS arm64 runtime bundle, private ABI 13 (53 slots), pinned to
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
checks generated cleanup and operation leases; neither suite changes the
arbitrary root-thenable identity boundary.
