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
Ordinary Dart `Map` and `Dictionary` containers are copied. Map keys use the
declared conversion and Dart equality; keys that become equal after conversion
are rejected. Dictionaries keep own string-keyed data properties and produce
objects with a null prototype.

[Value classes](values.md) use their output fields for callback arguments and
their constructor parameters for callback results. The two shapes may differ;
defaults and normal Dart constructor errors apply to results. An output-only
value class may be a callback argument. A lazy JS collection handle can still
contain that type, but reading a non-null element requires an input constructor.
[Selected references](classes.md) keep their original JS wrapper and class
identity. Lookalikes and wrappers from another module are rejected.

An enclosing Dart type parameter passes an [opaque payload](opaque.md) through
unchanged, including `undefined`, functions and objects with hostile properties.
No additional annotation is needed. It can also appear inside supported Lists,
records, Map values and Dictionaries; opaque Map keys remain unsupported.

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

## Returned functions

Dart closures can be returned directly, through a Future, or inside Lists,
records, Maps and Dictionaries. Function arguments and results may themselves
be typed functions:

```dart
@NAPI()
int Function([int]) makeAdder(int delta) =>
    ([int value = 7]) => value + delta;
```

```js
const add = makeAdder(2);
add(); // 9: the original Dart closure supplies its default
add(3); // 5
```

A Dart function's JavaScript facade validates inputs and converts the result using
its declared signature. Optional positional arguments and trailing named options
follow the ordinary export mapping. Omitting a parameter preserves the original
Dart closure's default. A nullable function becomes null; a Future-returning
function returns a Promise. These functions cannot be called with `new`.
`Stream<T> Function(...)` returns an async iterator supporting `for await`,
normal completion and `return()` cancellation. It uses the same ownership and
resource rules as [Stream exports](streams.md).

An explicit undefined for an ordinary optional positional parameter currently
selects its default only in trailing argument slots. For example,
`fn(2, undefined)` may use the second default, but `fn(undefined, 3)` throws a
TypeError instead of shifting arguments. Named defaults and trailing omission
work normally. Opaque payloads that admit undefined preserve it as a value.

A live JavaScript function keeps its Dart closure and captured values alive.
An unreachable facade and its captured values can be garbage-collected.
Captured resources must remain open while the function uses them. Omitted
resource defaults on returned functions do not yet acquire operation leases.
Returning the same Dart function with the same conversion signature reuses its
JavaScript facade; different signatures have separate facades. Passing that facade back restores
the original Dart function. A JavaScript function passed through Dart with the
same signature returns as the original JavaScript function.
When input and output conversions differ, such as a value class with different
constructor and getter shapes, returning that function creates a facade that
applies the required conversions.

Resource arguments and results keep the normal resource-operation rules,
including waiting for an accepted asynchronous invocation before cleanup.
Capturing a resource in a closure does not create an implicit resource lease.

## Ownership and identity

A live Dart function reference retains its JS callback. Fields, collections,
closures, timers and microtasks can keep it after the exported call returns.
Within one module, the same JS function and conversion signature reuse the same
Dart adapter. Positional parameter names and the export used to pass it do not
change that identity. Parameter kinds, named parameter names, scalar policies
and synchronous/async results are part of the conversion signature.

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

Resource closing rejects new resource operations and waits for accepted ones.
An asynchronous callback with resource payloads keeps its operation alive until
its Promise settles, even if the enclosing synchronous export has returned.
Callbacks without resource payloads do not extend unrelated resource operations. Calling close
or unregister from inside a callback preserves already accepted work. Resource
cleanup may itself accept a callback. Teardown releases private state without
invoking JS or business cleanup.
Workers and separately loaded modules have independent caches and owners.
Retaining a callback does not extend a completed resource operation. A later
exported call opens its own operation; a detached Timer cannot start resource
access through a saved callback. Ordinary references and opaque payloads retain
their usual lifetime when a callback runs after the original export returns.

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
mapping. Callbacks support required and optional positional parameters and named
parameters. Payloads use the ordinary scalar, binary snapshot, `SharedBytes`,
container, value-class, selected-reference, resource and opaque mappings, with
synchronous or Future results; void is also supported.

An omitted optional positional parameter is omitted from the JavaScript call.
Named parameters become one trailing options object containing only the provided
properties, with a null prototype and own data properties. The object is omitted
when all named parameters are optional and none
are provided; required named parameters always require an options object.

```dart
@NAPI()
int notify(int Function({int count}) callback) => callback();
```

```js
notify(({count = 7} = {}) => count); // 7
```

JavaScript owns callback defaults. Explicit null stays null. An opaque payload
containing undefined keeps its argument slot or named property, while normal
JavaScript default expressions still apply to that undefined value. Omitted
parameters skip payload conversion and resource admission.

Generic function signatures, nullable outer Future results, FutureOr and opaque
Map keys receive diagnostics.
Typed function elements in `JsArray` and `JsMap` are not yet supported.
[Stream exports](streams.md) retain input
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
