# Resource bindings and operation leases

Both backends generate resource classes from the same declaration. A resource
uses a designated selected public cleanup method; ordinary reference classes do
not gain a disposal API.

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
resource policy. The alias fixes all or some real Dart type arguments before
cleanup and other member signatures are checked. Generic resource classes also
support [opaque payloads](opaque.md): fields, callbacks, Future and Stream results
preserve the declared payload mapping and normal resource leases. Cleanup
parameters may use the class's type parameters; the cleanup method cannot declare
its own generic parameters. Selected generic ancestors use the same
[bijective opaque parameter mappings](opaque.md#reference-inheritance) as ordinary
reference classes. A selected subclass inherits the resource contract; its cleanup
call shape and defaults must remain compatible with every selected ancestor.

## Constant defaults

A resource parameter may use a public const constructor or a public
[const object binding](arguments.md), for example
`read([Resource resource = const Resource(7)])`. Omission and `undefined` select
that same canonical Dart object; they do not create a fresh resource per call.
Named parameters and nullable parameters follow the usual presence rules.

Default resources use the same operation leases as explicit inputs. Cleanup
waits for accepted Future or Stream operations. Once the canonical resource is closing
or closed, another call using that default is rejected; callers may supply a
different open resource explicitly. Built-in List, Map, Dictionary and record
defaults may also contain resources. Their leaves, including Map keys and repeated
aliases, are retained before callbacks, signal getters or value constructors run.
The original Dart const containers and objects retain their identity.
[Value-class input properties](values.md) can also default to resources, directly
or inside built-in containers. Their leases begin when conversion selects the
default, before later input fields or callbacks run, and last through the exported
operation. A closed default fails before the value constructor and business code
run; conversion and constructor failures release any acquired leases. An explicit
null selects no default when the property is nullable.

Resources stored in const value-object defaults are retained too, including
private fields, inherited fields and nested objects. Discovery uses the evaluated
constant's stored state; it does not invoke business getters or retain constructor
arguments that the object discards. Each resource must match a selected resource
view. Generic resources need the corresponding concrete alias.

A resource can be named through its public const constructor or binding, or
through public stored fields of an accessible default. A getter that computes a
value cannot supply that path. Resources that have no such expression produce
`NAPI_DEFAULT`. Custom const collection implementations with scalar or structural
data elements use the same stored-field rules; resource discovery does not call
their computed getters or iterators. See [argument defaults](arguments.md)
for element type restrictions.

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

[JavaScript collection handles](collections.md) retain resource elements when
Dart accesses them, rather than traversing the container during admission.
Saved handles use the operation of the current exported call. This also covers
accesses first made after `await` and during a stream subscription. A detached
Timer cannot start a new resource use after its exported call has finished.

Synchronous calls release after result conversion, including failure paths.
Future calls retain their leases through result conversion and the public
Promise's actual settlement. Dropping that Promise does not cancel Dart work or
release its leases. Accepted pending calls retain their inputs, including
cleanup's own exempt receiver, even when the business Future does not capture
those inputs or retain its completion callbacks.

A genuine Promise assimilates a callable `then` on its root result. For an object
result with resource leases, the generated Node binding observes the public
Promise with [`node:v8` promise hooks](https://nodejs.org/api/v8.html#promisehooksonsettledsettled)
and releases on a subsequent microtask. This waits for recursive thenable
adoption without attaching a hidden rejection handler, rereading `then` or
changing the host's `unhandledRejection` / `rejectionHandled` Promise identity.
Primitive/void results and rejected conversions need no settlement observer.
Calls that may acquire resources lazily through collection handles prepare this
tracking before business code starts, even if their initial lease set is empty.
Other calls with no resource leases do not activate it. Native acknowledgement
returns to Dart through its owning event pump, not a reentrant V8 hook callback.

The observer is private to each loaded module and is removed when its last
observed operation has finished. While active, Node invokes it for other Promise
settlements in that environment too. Independent active modules therefore have
additive hook cost. See the [supported Node versions](../README.md#verify);
this does not establish browser support. Environment teardown discards pending
bindings and native owners without executing JavaScript or business cleanup in
a dead realm.

Promise assimilation can fulfill with a different value or reject instead of
returning the original root thenable. The binding preserves standard Promise
semantics and does not hide `then`, box results or fabricate a Promise-like
object. Unconditional identity for arbitrary root thenables remains an explicit
boundary in [Future contracts](futures.md).
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

## Dart lifetime controls

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

`operation.run(body)` makes that operation available as `ResourceOperation.current`
while the body and its asynchronous continuations execute. It preserves the Dart
error Zone. This scope does not extend the operation's lifetime: resource access
after `release()` is rejected.

The cleanup callback runs in the first disposal call's Zone even if the last
lease is released in another Zone. The cached Future follows Dart error-zone
rules; generated adapters use their owning runtime Zone. Asynchronous errors and
stacks are forwarded without applying Zone error interception twice. Synchronous
throws follow normal Zone interception when converted to asynchronous failures.

## Compatibility

Resource bindings require the pinned Dart SDK and supported Node runtime.
Native currently supports macOS arm64; Wasm uses Dart WasmGC. See
[native requirements](native.md) and [supported toolchains](../README.md#verify).
