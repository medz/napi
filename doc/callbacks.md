# Synchronous borrowed callbacks

A function-typed input lets Dart call JavaScript during one synchronous exported
call. The ordinary Dart signature supplies the callback type:

```dart
@NAPI()
int twice(int Function(int) callback, int value) =>
    callback(value) + callback(value + 1);
```

```ts
import {twice} from 'your-package';
twice(value => value * 2, 3); // 14
```

Both targets validate the callback before entering business code, convert each
Dart argument to JavaScript, invoke it with an undefined receiver, and convert
its result back to Dart. Scalar, nested List and record conversions follow the
same precision, UTF-16, nullability and structural validation rules as exports.
`@NAPI(bigint: true)` also applies to integers inside callback signatures.

## Lifetime and reentry

The adapter is borrowed for the entire synchronous export, including its output
conversion. Repeated calls and reentry into another export of the same module
are supported. Nested calls own independent adapters. All adapters expire on
normal or exceptional exit; storing one in a Dart field does not extend it.
Calling it later, including from a microtask or timer, raises an expired-callback
error before touching JavaScript. Expiry drops the borrowed function even if
Dart keeps the expired adapter alive.

Resource operation leases remain held during callback execution and reentry.
If a callback requests cleanup of the active resource, cleanup waits for the
outer operation. Adapters expire before the binding releases that operation,
so cleanup cannot reactivate an escaped callback.

Native supports same-module reentry on its owning thread. Reentry into a
different active native Dart isolate remains the existing explicit limitation
in [native.md](native.md). Worker environments own independent adapters and
exception references; teardown does not invoke callbacks or business cleanup.

## Results and errors

A typed result must pass the declared conversion. A `void` callback discards its
return value: the binding does not read `then`, await a returned Promise or add
a rejection observer. Promise-returning callback signatures require a separate
async contract and are currently rejected.

Dart can catch a callback failure, recover, call another callback, replace the
failure with a Dart error, or save and rethrow it later. JavaScript throws retain
their exact original value, including objects, symbols, null and undefined.
They cross Dart as a private exception carrier; business code must not interpret
that carrier as the original JS object's Dart type. A saved exception also keeps
its value when subsequently rejected by an exported Future.

Conversion failures participate in the same recovery path. A JS exception while
reading a callback result is cleared from Node's pending-exception state before
Dart resumes. Native handles for each invocation cover argument conversion,
invocation and result conversion, then close; saved exceptions use independently
owned references. Their acyclic collection and explicit cross-heap-cycle
ownership follow [the generic payload ownership contract](opaque.md#ownership).

## Supported signatures

Callbacks are direct inputs to synchronous functions, constructors, methods
and setters. Nullable inputs and optional/default-null outer parameters use the
ordinary argument-presence rules. External selections use the same mapping.
Callback signatures currently require positional parameters with no defaults;
their inputs and result may contain supported scalars, Lists and records, and
the result may be void.

Optional/named parameters inside a callback, generic callback signatures,
callback outputs, nested callback values, Future/FutureOr callback results,
callbacks passed into Future-returning exports or resource cleanup, and callback
payloads containing bound instances, generic payloads, Maps or value classes
receive generation diagnostics. Retained registrations, Promise callbacks and
stream subscriptions remain separate work. A generic payload that happens to
be a JS function is stored unchanged; it is never inferred to be a callback.

## Verification and measured cost

Dart 3.13.5, Node 24.19.0/26.11.1 and TypeScript 7.0.2 were tested on macOS
arm64. Each backend/version passed 15 fresh-process scenarios and eight TS
configurations using annotated and externally selected packages, packed and
installed after removing their business/build sources. The complete existing
native/Wasm consumer suites also passed, with 527 Dart tests (one Windows-only
skip locally) and 23 Wasm resource-kernel tests. Native remains coupled to the
experimental runtime documented in [native.md](native.md).

The same scalar/Counter package grows from 6,588,276 to 6,588,516 bytes with
ABI13: the bridge adds 240 bytes; loader/declarations are byte-identical and AOT
size is unchanged. The existing 1,052 VM objects are reused. Seven ordinary Wasm
fixtures retain all 21 generated entrypoint/call/boundary files byte-for-byte.

Local ordinary native-path measurements used A/A and three balanced ABBA rounds
per Node version. Initial median changes were -0.88% to +1.46% across functions,
getters, methods, constructors and event-loop turns. The Node 24 getter's initial
+11 ns result did not repeat in an independent one-million-call A/A/ABBA check:
752.19 ns baseline versus 750.49 ns candidate (-0.23%). These measurements do not
establish a universal performance bound.

For active callbacks, a warmed Dart loop invoked `value => value + 1` 100,000
times through the installed package, checking the sum. Median time per call:

| Path | Node 24 | Node 26 |
| --- | ---: | ---: |
| Dart AOT to JS callback | 246 ns | 247 ns |
| Dart Wasm to JS callback | 112 ns | 109 ns |
| JS to Dart AOT `add` export, separate control | 912 ns | 895 ns |
| Pure JS loop, lower-bound control | 3.24 ns | 2.45 ns |

The native/control runs used A/A plus balanced repeated ordering; Wasm used A/A
and six additional samples per version. The controls execute different paths,
so subtracting them is not an isolated bridge-cost measurement. These scalar
loops do not measure application throughput, structural payload costs or memory
bounds; the 100,000-call functional test separately verifies repeated invocation.
