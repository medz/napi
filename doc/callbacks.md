# Callbacks

Ordinary typed Dart functions define callback arguments and results. No callback
annotation, registration wrapper or name list is needed:

```dart
final callbacks = <int Function(int)>[];

@NAPI()
void register(int Function(int) callback) => callbacks.add(callback);

@NAPI()
bool unregister(int Function(int) callback) => callbacks.remove(callback);

@NAPI()
Future<int> run(Future<int> Function(int) callback) => callback(41);
```

```ts
import {register, unregister, run} from 'your-package';
const callback = (value: number) => value + 1;
register(callback);
unregister(callback); // true
await run(async value => value + 1); // 42
```

Both targets validate functions before business code, convert Dart arguments to
JavaScript, invoke with an undefined receiver, and convert results back to Dart.
Scalars, Lists and records follow the ordinary precision, UTF-16, nullability
and structural validation rules. `@NAPI(bigint: true)` applies inside callbacks.

## Ownership and identity

A live Dart function reference retains its JS callback. Fields, collections,
closures, timers and microtasks can keep it after the exported call returns.
Within one module, the same JS function and conversion signature reuse the same
Dart adapter. Parameter names and the export used to pass it do not change that
identity; different scalar policies or synchronous/async results do.

Business code decides registration behavior. In the example, duplicate entries
are allowed and each `unregister` removes one entry. Removing one root does not
invalidate another Dart reference. The bridge has no global unregister or
implicit revocation. Keeping only the original JS function does not keep an
unused Dart adapter alive: the adapter cache is weak. Native cross-heap cycles
still require explicit business clear/unregister, as described in
[generic payload ownership](opaque.md#ownership).

An accepted async invocation retains its adapter, original JS function and
completion state until settlement. Scalar/List/record arguments are already
snapshotted by value; their original Dart objects need no additional lifetime.
Success, rejection and startup failure release private invocation roots.

Resource closing rejects new resource operations and waits for accepted ones,
including an awaited callback result. Calling close or unregister from inside a
callback preserves already accepted work. Resource cleanup may itself accept a
callback. Teardown releases private state without invoking JS or business cleanup.
Workers and separately loaded modules have independent caches and owners.

## Promise results and errors

`Future<R> Function(...)` declares a JS callback returning a genuine
`Promise<R>`, including Promise subclasses and cross-realm Promises. Plain values,
raw thenables, Promise proxies and prototype/tag counterfeits fail before their
properties are read. A caller can explicitly use `Promise.resolve(thenable)`.
The fulfilled value must pass the ordinary strict input conversion for `R`.

Consumption uses captured Promise intrinsics, so an own `then` override is not
called. Intrinsic constructor/species access can still throw; that original
value reaches Dart. A synchronous invocation, argument-conversion or Promise
admission failure throws during the Dart callback call. A genuine Promise
rejection or fulfillment-conversion failure completes its returned Future with
an error. An enclosing exported Future maps either failure to JS rejection.

`Future<void>` still requires a Promise and discards its fulfilled value.
A synchronous `void` callback simply discards its return without reading `then`
or observing a returned Promise; an unhandled rejection stays visible to JS.

Dart can catch failures, recover, save them and rethrow them later. JS Error,
object, symbol, number, null and undefined failures retain exact identity/value.
They cross Dart in a private exception carrier, not as a converted Dart model.
Native per-invocation handle scopes cover conversion and JS execution; saved
exceptions own independent references.

Native async delivery queues owned results for the correct isolate's existing
event pump. It does not enter Dart directly from a Promise reaction, which may
run while another isolate is active. The pump drains a bounded batch before
Dart microtasks; unresolved callback Promises alone do not keep Node alive.
Ordinary direct reentry into another active native isolate remains the
[existing limitation](native.md).

## Supported signatures

Callbacks are direct inputs to synchronous and Future-returning functions,
constructors, methods, setters and resource cleanup. Nullable/default-null outer
parameters preserve normal presence rules. External selections use the same
mapping. Callback parameters currently require positional parameters without
defaults, with scalar/List/record payloads and synchronous or Future results;
void is also supported.

Optional/named parameters inside a callback, generic callback signatures,
callback outputs, nested callbacks, nullable outer Future results, FutureOr,
and callback payloads containing bound instances, opaque values, Maps or value
classes still receive diagnostics. Streams and cancellation remain separate
requirements. A generic payload that happens to be a JS function stays an opaque
value; it is never inferred to be a callback.

## Verification

The fixture builds annotated and externally selected packages, packs and installs
them offline after removing the original business/build sources. It exercises
identity, weak collection, delayed invocation, startup failures, strict Promise
inputs, exact errors, concurrent results, resource closing, foreign-owner
completion, normal/terminated Workers and queued teardown. TypeScript consumers
run in eight strict/optional-property/function-variance configurations.
Native currently requires the experimental macOS arm64 ABI14 runtime bundle;
compiler/runtime versions and broader limits are in [native.md](native.md).

The 2026-10-17 final validation passed 537 Dart tests (one Windows-only local
skip), 23 Wasm resource tests, and full native/Wasm installed consumers on Node
24.19.0 and 26.11.1. Each callback package ran 24 isolated scenarios and eight
TypeScript configurations, using Dart 3.13.5 and TypeScript 7.0.2. Format,
analysis and the clean package dry-run also passed.

## Retained-callback cost

The final ABI14 comparison used the same Dart callback source as the earlier
borrowed fixture, on macOS arm64 with Node 24.19.0 and 26.11.1. Each case used
fresh-process A/A samples and three balanced ABBA rounds. Median times in ns:

| Path and unit | Node 24, borrowed → retained | Node 26, borrowed → retained |
| --- | ---: | ---: |
| Native Dart loop, per JS callback | 252 → 255 (+1.16%) | 250 → 257 (+2.83%) |
| Native `callTwice`, per outer call | 1,414 → 1,558 (+10.15%) | 1,412 → 1,517 (+7.47%) |
| Wasm Dart loop, per JS callback | 114 → 119 (+3.87%) | 109 → 109 (-0.16%) |
| Wasm `callTwice`, per outer call | 563 → 316 (-43.91%) | 534 → 277 (-48.11%) |

The loop invokes an already-converted callback 100,000 times. `callTwice` passes
the same JS function into Dart on each call and invokes it twice, so it includes
adapter lookup. Native identity maintenance adds a repeatable 105–144 ns per
outer call; it is not cost-free. Direct function references, borrowing inside
the local handle scope, combined native calls and allocation-free cache-hit keys
removed the first implementation's approximately 37% regression. Ordinary native
export controls changed between -2.23% and +1.13%, with no consistent slowdown
across the independent runs. These results do not measure async callback
throughput or establish a general application performance bound.

The unchanged scalar/Counter native package adds 17,872 bytes (+0.271%). The
same-source native callback package adds 21,251 bytes (+0.307%), or 2,456 bytes
in its real npm tarball. The Wasm callback package shrinks by 9,882 raw bytes
(-1.719%) but its tarball grows by 816 bytes. Callback source paths differ from
the earlier installed fixture, so sizes compare complete generated packages,
not isolated bridge instructions. The broader new conformance fixture is
excluded from this comparison. The native bundle reuses all 1,052 VM objects;
no SDK download or VM rebuild was needed. Raw samples, artifact hashes and
superseded measurements remain in
`.dart_tool/evidence/20261017-retained-callbacks/cost/`.

## Earlier borrowed-callback cost baseline

These measurements record PR #170's ABI13 borrowed-adapter implementation, before
retained and async adapters. They are not cost measurements of the current path.

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
