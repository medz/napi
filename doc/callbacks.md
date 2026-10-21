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
[Binary snapshots](binary.md) and `SharedBytes` work directly or inside nullable
Lists and records, including fulfilled Future results. `Uint8List` becomes a
`Uint8Array` and `ByteBuffer` becomes an `ArrayBuffer`; each crossing makes an
independent copy of the declared bytes. `SharedBytes` retains the original
`Uint8Array`, its view window and live contents. Shared backing memory is not
supported. Detached or out-of-bounds views fail conversion; retained shared
views also check their current window when Dart accesses them.

[JS collection handles](collections.md) also work as callback arguments and
results, directly or inside Lists and records. Their original Array/Map identity
and live contents are preserved:

```dart
@NAPI()
JsArray<T> transform<T>(
  JsArray<T> Function(JsArray<T>) callback,
  JsArray<T> source,
) => callback(source);
```

The callback receives the original JS array. It may return that array or another
array; Dart receives a handle with the declared element policy. Elements use the
same conversion rules as ordinary handle arguments.

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
completion state until settlement. Scalar/List/record arguments and binary
snapshots are already copied by value; their original Dart objects need no
additional lifetime. `SharedBytes` leaves retain their original JS views through
settlement and observe later mutation, resize or detachment.
Handle leaves retain their original JS containers instead of copying contents.
Saving a callback result handle in Dart keeps that container usable after the
callback completes.
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

Native async results are delivered in the owning Dart isolate. Unresolved
callback Promises alone do not keep Node alive. Direct synchronous reentry into
another active native isolate remains [unsupported](native.md).

## Supported signatures

Callbacks are direct inputs to synchronous, Future-returning and Stream-returning
functions, constructors, methods, setters and resource cleanup. Nullable/default-null outer
parameters preserve normal presence rules. External selections use the same
mapping. Callback parameters currently require positional parameters without
defaults, with scalar, binary snapshot, `SharedBytes`, List, record and JS-handle
payloads and synchronous or Future results; void is also supported.

Optional/named parameters inside a callback, generic callback signatures,
callback outputs, nested callbacks, nullable outer Future results, FutureOr,
and callback payloads containing bound instances, bare opaque values, Dart `Map`
containers or value classes receive diagnostics. [Stream exports](streams.md) retain input
callbacks through subscription completion. [Explicit cancellation](cancellation.md)
never revokes a retained callback or cancels a JavaScript Promise returned by it.
A generic payload that happens to be a JS function stays an opaque
value; it is never inferred to be a callback.

Native callbacks currently support macOS arm64. See [native requirements](native.md)
and [supported toolchains](../README.md#verify).

## Performance

Each callback invocation crosses the Dart/JavaScript boundary. Lists, records
and binary snapshots are copied and validated on each call. `SharedBytes` and JS
handles retain their live views and containers.
For repeated work, passing a batch can reduce invocation overhead. Reusing a
callback preserves its adapter identity but does not remove per-call conversion.
