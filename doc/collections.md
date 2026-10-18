# Collection ownership

Ordinary collection conversion and explicit shared access have different ownership
contracts. The model follows napi-rs: convert ordinary owned values, retain a
handle when accessing an existing JavaScript container, and export classes and
methods when sharing application state owned by Dart.

| Dart API | JavaScript value | Ownership | Status |
| --- | --- | --- | --- |
| `List<T>` | `Array<T>` | Independent container on each conversion | Implemented on both targets |
| `Map<K, V>` | `Map<K, V>` | Independent container on each conversion | Implemented on both targets |
| `Dictionary<V>` | String-keyed object | Independent container on each conversion | Implemented on both targets |
| `JsArray<T>` / `JsMap<K, V>` | Original JS Array or Map | Retains the existing JS container | Scalar and direct opaque payloads on both targets |
| Exported Dart reference class | Bound class instance | Dart owns its state; methods expose supported operations | Implemented on both targets |

See [structural conversion](structural.md) for strict input validation, element
policies, traversal limits and converted Map-key collisions. Copying a container
does not imply that every element is copied: selected reference leaves preserve
their wrapper identity, and supported opaque leaves preserve their original JS
values. Use [shared byte views](shared-bytes.md) for supported binary sharing.

## Explicit JS handles

`JsArray<T>` exposes `length`, `get(index)` and `set(index, value)`. `JsMap<K, V>`
exposes `size`, `has(key)`, `get(key)`, `set(key, value)`, `delete(key)`, `clear()`
and an `entries` iterable of Dart `(K, V)` records. JavaScript supplies the
container; these types have no allocation or `.view` constructor and do not
implement Dart's entire List/Map interface.

```dart
@NAPI()
JsArray<int> increment(JsArray<int> values) {
  values.set(0, values.get(0)! + 1);
  return values;
}
```

JavaScript calls `const result = increment(source)`: `result === source` is true.
TypeScript uses ordinary `Array<T>` and `Map<K, V>` types. There is no generated
collection facade, proxy or extra initialization. Ordinary Dart List/Map bindings
still copy their containers.

Supported scalar elements and keys are `bool`, `String`, `int`, `double`, `BigInt`
and their nullable forms. The existing strict scalar policy applies on every
access: default ints are safe JS numbers; `@NAPI(bigint: true)` ints use signed
64-bit JS bigints; BigInt is arbitrary precision. Doubles preserve NaN, infinity
and negative zero, and strings preserve UTF-16 code units. Direct opaque type
parameters also work, for example `JsArray<T>`, `JsArray<T?>`,
`JsMap<String, T>` and `JsMap<K, V>` on an exported generic declaration. They use
the same [storage-only carrier contract](opaque.md) as direct opaque arguments:
reads and writes preserve the raw JS value without inspecting or coercing it.
Opaque Map keys keep JavaScript SameValueZero semantics, including object and
symbol identity. No additional annotation is needed. Direct inputs,
reference-class members, nullable handles and Future/Stream output payloads are
supported. Handles also compose inside Lists, Map values, Dictionaries, records
and value classes: the outer containers copy while each handle retains its
original JS source.

```dart
@NAPI()
List<JsArray<int>> echo(List<JsArray<int>> values) => values;
```

For `const output = echo([source])`, the returned outer array is new and
`output[0] === source`. Admission does not inspect the handle's elements; later
Dart reads and writes observe the live source. Handles cannot be structural Map
keys, elements of another handle, or callback parameters/results. Other handle
element types remain unsupported.

Admission checks the genuine container brand without walking its contents.
Cross-realm containers work; Proxy containers are rejected. Each operation
observes the current contents and validates only the values it accesses:

- Array indices must be integers from 0 through `0xfffffffe`. `get` returns Dart
  null at or beyond the current length. Inside the current length it performs
  ordinary property lookup, including inherited values and getters. Undefined
  (including an unfilled hole with no inherited value) is invalid for a scalar,
  even a nullable scalar. A present scalar null requires a nullable type. An
  opaque element accepts either value; present null and undefined are non-null
  Dart carriers, distinct from an out-of-range result's Dart null.
- Array `set` uses ordinary property assignment, including setters and extension.
  It may create holes. A rejected assignment throws TypeError. Getter/setter
  reentry into the same owner is allowed; their exact thrown JS values, including
  null and undefined, are preserved. Direct synchronous entry into another native
  module's isolate while Dart is active remains rejected; see
  [native runtime limitations](native.md#runtime-and-verification). No
  transactional bulk mutation or snapshot rules are implied.
- Map operations use captured native methods and SameValueZero keys. `get`
  returns Dart null for an absent key; `has` distinguishes absence from a stored
  null. Present undefined fails scalar value conversion; opaque values preserve
  it. A present opaque null or undefined is a non-null Dart carrier, so Dart can
  distinguish it from absence. `has` and `delete`
  do not read or validate the stored value. There is no coercion of keys.
- Map entries use its native insertion-order iterator, not keys plus later
  lookups. Each step converts that entry's key and value. Later mutations follow
  JS Map iteration rules; an exhausted iterator stays exhausted. A conversion
  failure propagates through the Dart iterator. The iterator retains its handle.

A native handle owns a host reference; a Wasm handle retains a traced externref.
The same source and element policy reuse a still-reachable Dart handle within one
module. A source alone does not pin an otherwise unreachable Dart handle, and
different modules may independently retain the same source. Returning a handle
requires its original module and element policy; a fake Dart implementation or
returning a number-policy handle through a bigint-policy signature is rejected.
Opaque parameter names do not change an otherwise identical runtime policy;
scalar and opaque policies remain different.

An extracted opaque element owns its own carrier. Deleting or replacing its
source slot, or dropping the container handle, does not invalidate a payload
still saved by Dart. Clearing that saved field permits collection. Keeping only
the original JS source alive does not pin an unused Dart handle. An opaque
resource wrapper remains an uninterpreted JS value: retaining it does not acquire
a permanent resource lease or prevent explicit cleanup. Typed reference/resource
elements remain unsupported.

Handles remain usable when saved by Dart or across await/Timer callbacks in their
owner. Existing Future/Stream retention and resource operation leases apply;
there is no permanent resource lease. A synchronous return preserves the source
without reading its `then`. A Future return uses standard Promise resolution,
including assimilation of a callable `then` on the original container. A Stream
item is nested inside IteratorResult and preserves source identity without
assimilation. Retention does not transfer a handle between workers or make
concurrent access safe. Native cross-heap cycles follow the explicit
[ownership contract](opaque.md).

The host operations are captured per generated module and emitted only when a
handle is used. Both backends reuse the existing owner/error transport; no C ABI
or VM extension is added. Native calls still pay for scoped host invocation and
scalar conversion or opaque ownership. Wasm still uses the pinned experimental Dart 3.13.5 SDK
adapter. See [supported toolchains](../README.md#verify).

## Measured cost

A 2026-10-18 sample on Apple M3 Max, macOS 27.0.1 arm64, Dart 3.13.5 and the
ABI 15 native runtime measured a retained 32-element `JsArray<int>` and a
one-key `JsMap<String, int>`. Each operation crosses JS → Dart → JS container →
Dart → JS, including strict scalar validation and ownership transport.

| Backend / Node | Array get | Array set | Map get | Map set |
| --- | ---: | ---: | ---: | ---: |
| Native / 24.19.0 | 1,771.9 ns | 1,790.6 ns | 1,989.4 ns | 1,992.3 ns |
| Native / 26.11.1 | 1,737.5 ns | 1,751.7 ns | 1,956.5 ns | 1,989.5 ns |
| Wasm / 24.19.0 | 180.0 ns | 195.8 ns | 164.5 ns | 179.8 ns |
| Wasm / 26.11.1 | 179.3 ns | 196.6 ns | 165.9 ns | 171.8 ns |

Each fresh process warmed up for 10,000 calls and measured three 100,000-call
batches. The table takes the median per process, then the median of two handle
processes in a balanced control/handle/handle/control sequence. Separate repeated
control runs estimated noise; output and mutations were checked outside timing.
This small valid-scalar sample does not measure large collections, errors, GC
pressure, memory footprint or other platforms. It predates opaque element
support and does not measure extracted payload allocation or retention.

An ordinary scalar-and-Counter fixture that never uses handles produced identical
generated text and unchanged unpacked package sizes before and after this feature:
6,654,143 bytes native and 129,075 bytes Wasm. The native AOT stayed 1,027,056
bytes and Wasm core stayed 88,383 bytes. Binary hashes differed; these sample sizes
do not imply deterministic binaries or a universal zero-cost guarantee.

## Dart-owned state

Expose Dart-owned collections through an exported class and methods when callers
need shared state. Ordinary List/Map return values remain independent conversions;
exporting a class does not change their meaning. Arbitrary Dart Lists and Maps do
not automatically gain bidirectional live adapters or JavaScript proxies.

In particular, a Dart Map may use a custom equality policy that JavaScript Map
cannot reproduce. Exported methods can execute that policy in Dart; a converted
Map instead follows the documented conversion and collision rules.

## napi-rs comparison

napi-rs converts `Vec<T>` into an Array and string-keyed `HashMap`/`BTreeMap` into
objects. Its `Array` handle operates on an existing JS array, and explicit
references support retention beyond a callback. These are distinct mechanisms,
not a universal live adapter for arbitrary Rust containers. See the official
[type conversion table](https://napi.rs/docs/concepts/type-conversions#arrays-tuples-maps-and-sets),
[Array implementation](https://github.com/napi-rs/napi-rs/blob/main/crates/napi/src/bindgen_runtime/js_values/array.rs),
[Map conversion implementation](https://github.com/napi-rs/napi-rs/blob/main/crates/napi/src/bindgen_runtime/js_values/map.rs)
and [reference lifetime guide](https://napi.rs/docs/concepts/understanding-lifetime#javascript-value-reference).

We follow that ownership distinction. Existing Dart Map exports continue to use
JavaScript Map; `Dictionary` is the explicit object representation. The comparison
does not change those public mappings or copy napi-rs's backend ABI.
