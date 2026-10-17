# Resource state and operation leases

The shared Dart runtime provides `ResourceControl` through
`package:napi/runtime.dart`. This is the state kernel for #124, not generated
resource support. Both backends still diagnose resource bindings; generated
cleanup APIs, argument conversion, native scheduling and cross-backend consumer
conformance remain to be implemented. Ordinary reference classes do not use this
control and do not gain a `dispose` method.

## Ownership and aliases

`ResourceControl.forObject(raw)` associates one control with the original Dart
class instance using an `Expando`. Its key uses identity, not `operator ==`.
Every alias, selected binding view and replacement JavaScript wrapper must look
up that same raw instance. A surviving Dart instance therefore keeps its closing
or closed state when its wrapper is collected and later recreated. The kernel
neither maintains a permanent strong registry nor relies on wrapper finalization.

An open or closing control retains its raw owner. An accepted operation lease
retains that control until `release()`. Release is idempotent and drops the
lease's reference to the control. Completed cleanup drops the control's owner
reference and cleanup closure; the weak association still retains terminal state
while the raw object survives. Unreachable object/control cycles may be collected
without cleanup. Explicit disposal is the required cleanup guarantee; a finalizer
is not a substitute. As with `Expando`, keys must be class instances, not strings,
numbers, booleans or records.

Shared controls do not decide whether two selected views declare compatible
cleanup methods. The compiler and binding layer must validate that contract
before exposing either view; choosing whichever cleanup policy is encountered
first is not acceptable.

## State and cleanup

| State | New operation | Dispose |
| --- | --- | --- |
| `open` | Accepted with a lease | Switches to `closing`; records the first cleanup closure |
| `closing` | Throws `StateError` | Returns the same pending future |
| `closed` | Throws `StateError` | Returns the same completed or failed future |

Cleanup starts once all accepted leases have been released. Synchronous cleanup
closes immediately when invoked; asynchronous cleanup remains closing until its
future settles. Either success or failure is terminal. The disposal future
forwards an asynchronous error and its stack without reapplying the Zone's error
interception. A synchronous throw follows the usual Zone interception when it
becomes an asynchronous error. Cleanup is never retried, and its errors do not
escape a lease's `release()` call.

The cleanup callback runs in the first disposal call's Zone, even if the last
lease is released in another Zone. The cached future follows Dart's usual error
zone rules; runtime adapters must use their owning runtime Zone. Cleanup may
reenter disposal and observe the same future, but must not await its own
completion. Directly returning that future fails with `StateError`; indirect
self-dependencies cannot be detected.

## Adapter boundary

The following illustrates the kernel protocol, not generated consumer syntax:

```dart
final control = ResourceControl.forObject(raw);
final lease = control.retainOperation();
try {
  // Invoke business code and finish all use, including output conversion.
} finally {
  lease.release();
}

await control.dispose(() => raw.close(reason, force: force));
```

An asynchronous adapter retains its lease through settlement and conversion,
then releases it in `finally`, including failure paths. Disposal stops new work;
it does not cancel accepted work or release its lease early. The same rule will
apply to resource-valued arguments, callbacks and shared views, not just method
receivers. Returning or storing a resource without using it is a separate
identity/ownership decision for those adapters.

The binding layer validates and converts cleanup arguments before calling
`dispose`. The first accepted call captures the selected Dart cleanup method and
its original arguments/defaults in the closure; later calls do not replace it.
This permits existing cleanup signatures without adding artificial zero-argument
restrictions. Generated JavaScript API spelling and repeat-call argument
validation still need their own decision and consumer tests.

Deterministic Dart tests cover multiple leases, aliases/replacement wrappers,
synchronous and asynchronous cleanup, failure, reentry and differing release
Zones. They do not depend on GC timing and do not establish native/Wasm generated
resource conformance, native event-loop scheduling or runtime teardown behavior.

The same runtime test suite can run on the Dart VM and compiled Wasm without a
separate fixture or generated public API:

```sh
dart test test/runtime/resources_test.dart
dart test --platform node --compiler dart2wasm test/runtime/resources_test.dart
```

This kernel was tested with Dart 3.13.5 and Node 24.19.0. The Wasm test uses the
SDK's standard test runner loader; it does not validate the binding compiler's
resource emission or native Node-API event-loop integration.
