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
| Explicit JS collection handle | Original JS Array or Map | Retains the existing JS container | Planned in [#128](https://github.com/medz/napi/issues/128) |
| Exported Dart reference class | Bound class instance | Dart owns its state; methods expose supported operations | Implemented on both targets |

See [structural conversion](structural.md) for strict input validation, element
policies, traversal limits and converted Map-key collisions. Copying a container
does not imply that every element is copied: selected reference leaves preserve
their wrapper identity. Opaque leaves inside structural containers remain
unsupported. Use [shared byte views](shared-bytes.md) for supported binary sharing.

## Explicit JS handles

The planned handle API lets Dart retain and operate on an existing JS Array or
Map without converting the complete container. Returning the handle must return
the original JS object, so JavaScript continues to use its normal Array or Map
API. There is no additional generated JS collection facade. Public Dart type
names and the supported operation/element-type matrix are not finalized.

Reads must observe permitted later mutations, and writes must affect the original
container. Specify property access, missing entries, iteration, reentrant
mutation, validation and thrown JS values for each operation. These operations
must not silently inherit the snapshot converter's own-data-property rules or
promise arbitrary Dart List/Map behavior.

A retained native handle owns its JS reference; Wasm retains the corresponding
traced reference. Both targets must verify async use, garbage collection,
environment teardown and worker isolation. Retention does not make a JS value
transferable between environments or safe for concurrent access. Cross-heap
cycles follow the explicit [ownership contract](opaque.md).

This is the target contract, not a claim that collection handles are available.
Issue #128 remains open until real installed consumers verify both backends,
identity, access, failure, lifetime and TypeScript behavior.

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
