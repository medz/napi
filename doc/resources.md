# Resource bindings and operation leases

Both backends generate resource classes from the same declaration. A resource
uses its own selected public cleanup method; ordinary reference classes do not
gain a disposal API.

```dart
import 'package:napi/napi.dart';

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Counter {
  int value = 0;
  Counter();
  int increment() => ++value;

  @NAPI(name: 'release')
  void close([int reason = 7]) {
    // Release the Dart resource here.
  }
}
```

```js
import {Counter} from '@scope/example';
const counter = new Counter();
counter.increment();
const completion = counter.release();
console.log(completion === counter.release(9)); // true; first accepted reason wins
await completion;
```

`cleanup` names the original Dart method. Its ordinary export name, including
`@NAPI(name: ...)`, determines the JavaScript method. The method must return
`void` or non-nullable `Future<void>`; both expose `Promise<void>` because cleanup
may have to wait for accepted operations. The normal parameter, default,
presence and structural conversion rules apply. An excluded cleanup method,
unsupported result or unsupported generic signature produces a build diagnostic.

[Concrete class aliases](concrete-generics.md#resource-aliases) may use the same
resource policy. The alias fixes the real Dart type arguments before cleanup and
other member signatures are checked. Open opaque generic resource classes remain
unsupported.

## State and cleanup

| State | New receiver/input operation | Valid cleanup call |
| --- | --- | --- |
| `open` | Accepted with a lease | Switches to `closing`; records the first cleanup call |
| `closing` | Rejected | Returns the same pending Promise |
| `closed` | Rejected | Returns the same fulfilled or rejected Promise |

Every cleanup call validates its receiver and converts its arguments immediately.
The first accepted call captures the Dart method, converted values and defaults;
subsequent valid calls reuse the same live JavaScript Promise without replacing
that call. Invalid repeats reject their own Promise. Synchronous methods throw
for a closing/closed resource; Future methods reject.

Cleanup starts once all accepted operation leases have been released. A
synchronous cleanup closes when it returns; an asynchronous cleanup remains
closing until its Future settles. Either success or failure is terminal. Cleanup
is never retried, and its errors do not escape an operation's release path.
Cleanup may reenter disposal and obtain the same completion, but must not await
its own completion. The Dart kernel diagnoses a directly returned self-dependency;
indirect dependencies cannot be detected.

Returning an already closing or closed resource is allowed. It preserves wrapper
identity and permits repeated cleanup; using it as a new receiver or input is
still rejected. Cleanup's own raw resource is exempt from its argument leases,
including aliases of itself in nested arguments. Other resource arguments retain
normal leases through cleanup completion.

## Ownership and aliases

`ResourceControl.forObject(raw)` associates one control with the original Dart
class instance using an `Expando`. Its key uses identity, not `operator ==`.
Every selected view and replacement JavaScript wrapper shares that control. A
surviving Dart instance therefore keeps its state and cached Dart cleanup
completion when its wrapper is collected and recreated. Both backends weakly
cache the corresponding JavaScript Promise: every still-live completion is
reused. If that Promise itself has been collected, a later call remaps the same
Dart completion without running cleanup again. An ordinary interface view cannot
bypass the guard for an actual resource instance.

Selected resource views must agree on cleanup target, call contract and defaults.
Known conflicting hierarchies fail during compilation. A conflict discovered from
an actual object's unrelated selected memberships fails before exposure. The
binding never chooses whichever cleanup policy happens to be encountered first.

An open or closing control retains its raw owner. Accepted leases retain that
control until release; release is idempotent. Completed cleanup drops the owner
and captured cleanup closure. The weak association keeps terminal state while
the raw instance survives. There is no permanent strong resource registry.
Unreachable object/control cycles may be collected without cleanup. Explicit
cleanup is the guarantee; wrapper finalization never invokes business cleanup.

## Operation boundaries

An operation acquires its receiver lease before reading options. Presence and
direct reference inputs are checked before structural parameter conversion;
actual resource leaves are leased immediately on acceptance. This includes
Lists, Maps, Dictionaries, records and value classes. A later Proxy trap or
value constructor can therefore reenter disposal without closing an already
accepted resource early. It does not reread mutable JavaScript
getters in a second resource traversal. Repeated aliases acquire one lease per
raw control. Partial conversion failures release every lease already acquired.

Synchronous calls release after result conversion, including failure paths.
Future calls retain their leases through result conversion and the public
Promise's actual settlement. Dropping that Promise does not cancel Dart work or
release its leases. The adapter strongly retains accepted pending calls, including cleanup of its
own exempt receiver, even when the business Future itself does not capture its
inputs or retain its completion callbacks.

A genuine Promise assimilates a callable `then` on its root result. For an object
result with resource leases, the generated Node binding observes the public
Promise with [`node:v8` promise hooks](https://nodejs.org/api/v8.html#promisehooksonsettledsettled)
and releases on a subsequent microtask. This waits for recursive thenable
adoption without attaching a hidden rejection handler, rereading `then` or
changing the host's `unhandledRejection` / `rejectionHandled` Promise identity.
Primitive/void results and rejected conversions need no settlement observer.
Ordinary calls with no resource leases do not activate it. Native acknowledgement
returns to Dart through its owning event pump, not a reentrant V8 hook callback.

The observer is private to each loaded module and is removed when its last
observed operation has finished. While active, Node invokes it for other Promise
settlements in that environment too. Independent active modules therefore have
additive hook cost. This implementation is qualified for the Node versions below;
it does not establish a browser contract. Environment teardown discards pending
bindings and native owners without executing JavaScript or business cleanup in
a dead realm.

Promise assimilation can fulfill with a different value or reject instead of
returning the original root thenable. The binding preserves standard Promise
semantics and does not hide `then`, box results or fabricate a Promise-like
object. Unconditional identity for arbitrary root thenables remains an explicit
boundary in [Future contracts](futures.md); this resource work does not claim it.
[Callbacks](callbacks.md) and [Stream iterators](streams.md) have their own
operation-lifetime integration. Streams transfer the original call leases and
notify subscriptions when an owner closes. Cleanup waits for cancellation and
accepted delivery acknowledgements. Business cleanup errors take priority over
cancellation errors; otherwise the first cancellation error in registration order
is forwarded. [Explicit cancellation](cancellation.md) can request a Stream's
subscription cancellation; ordinary Futures retain their leases until actual
completion. [SharedBytes](shared-bytes.md) retains accepted host views through
these operation and delivery lifetimes; ordinary Dart byte storage is not
implicitly shared.

## Settlement observer cost

A local isolated Promise-settlement microbenchmark used Node 24.19.0 and
26.11.1 on macOS arm64, with three A/A and balanced A/B/B/A rounds. Each fresh
process used four warmups and eight samples of 200,000 immediate settlements.
On Node 24, no hook cost about 6.8–7.0 ns per settlement; one active observer
cost about 14.2–14.4 ns (roughly +7 ns), and eight observers about 65–66 ns.
Node 26 showed the same scale; A/A deviations stayed below 1.51%. This measures
the host notification cost, not total binding latency or a real-workload
slowdown. Only leased object results activate observation; applications with
several such pending module graphs should account for the additive cost.

## Generated operation cost

A separate generated package contains ordinary `Plain` and resource `Resource`
classes with identical getter, increment and Future bodies. Both live in the
same resource-enabled module, so the ordinary class already pays the empty
resource guard. This comparison isolates neither a resource-free module nor
cross-backend business equivalence beyond these small calls. Each backend/Node
combination used two A/A plus balanced A/B/B/A rounds in fresh processes; each
process warmed and measured five samples of 100,000 synchronous or 1,000 awaited
Future calls. The object Future allocates and returns a reference wrapper.

| Backend / Node | Method ns, ordinary → resource | Scalar Future µs, ordinary → resource | Object Future µs, ordinary → resource |
| --- | ---: | ---: | ---: |
| Native / 24.19.0 | 823 → 931 | 3.82 → 4.03 | 5.31 → 6.06 |
| Native / 26.11.1 | 819 → 912 | 3.56 → 3.67 | 5.09 → 5.57 |
| Wasm / 24.19.0 | 122 → 230 | 1.00 → 1.03 | 1.32 → 1.85 |
| Wasm / 26.11.1 | 106 → 189 | 0.97 → 0.98 | 1.16 → 1.48 |

The tested resource methods add roughly 83–107 ns, and object Futures add
0.32–0.75 µs including final-settlement observation. Same-target variation reached
2.87% on native and 9.42% on Wasm; small scalar-Future differences are within that
noise. These local microbenchmarks do not predict application throughput. Sources,
raw samples and balanced summaries are retained under
`.dart_tool/evidence/resource-bindings/cost/`. Resource-free synchronous artifact
and cost comparisons are recorded in [native measurements](native.md#resource-bindings-and-synchronous-modules).

## Shared Dart kernel

The low-level controls are exported by `package:napi/runtime.dart`:

```dart
final control = ResourceControl.forObject(raw);
final operation = ResourceOperation();
try {
  operation.retain(control);
  // Invoke business code and finish every use, including output conversion.
} finally {
  operation.release();
}
await control.dispose(() => raw.close(reason));
```

`ResourceOperation` deduplicates controls and releases in reverse acquisition
order. It detaches its retained state before release can invoke cleanup and
reenter the binding. Its optional exempt control is used for cleanup's own raw
resource, not arbitrary other resources.

The cleanup callback runs in the first disposal call's Zone even if the last
lease is released in another Zone. The cached Future follows Dart error-zone
rules; generated adapters use their owning runtime Zone. Asynchronous errors and
stacks are forwarded without applying Zone error interception twice. Synchronous
throws follow normal Zone interception when converted to asynchronous failures.

## Verification

`dart run tool/resource_fixture.dart [native-runtime-bundle]` builds a fresh Dart
consumer through the public package API, packs its npm package, removes original
business/build sources and installs offline into a relocated consumer. The shared
suite runs 25 fresh-process scenarios and checks strict TypeScript declarations,
cleanup signatures and
Promise identity, state guards, nested and distinct-resource leases, rollback,
thenable adoption, exact rejection events, wrapper GC/readoption, independent
module graphs, process liveness and normal/terminated Workers. The full Wasm and
native verification commands include this fixture.

The toolchain is Dart 3.13.5, Node 24.19.0/26.11.1 and TypeScript 7.0.2 in NodeNext
and Bundler modes. Native uses the experimental macOS arm64 runtime bundle,
private ABI 15 (57 slots), pinned to Dart revision
`04bcd1036cdc799ac6564988f159ee454d42c822`. Wasm uses that SDK's version-specific
compiler and host adapter, not WASI/emnapi. Other native targets and hosts remain
unqualified.

Deterministic kernel tests additionally cover cleanup Zones, multiple leases,
reentry, failed cleanup and partial-acquisition rollback on Dart VM and Wasm:

```sh
dart test test/runtime/resources_test.dart
dart test --platform node --compiler dart2wasm test/runtime/resources_test.dart
```
