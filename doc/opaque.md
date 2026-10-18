# Opaque generic payloads

Dart already declares generic parameter names and order. Export the declaration
with the ordinary annotation; supported generic parameters preserve JavaScript
payloads without interpreting them:

```dart
@NAPI()
class Router<T> {
  final Map<String, T> _values = {};
  Router();
  void set(String key, T value) => _values[key] = value;
  T? get(String key) => _values[key];
  bool has(String key) => _values.containsKey(key);
  void remove(String key) => _values.remove(key);
  void clear() => _values.clear();
}

@NAPI()
T identity<T>(T value) => value;
```

```ts
import {Router, identity} from 'your-package';
const router = new Router<{name: string} | undefined>();
const payload = {name: 'example'};
router.set('entry', payload);
router.get('entry') === payload; // true
router.set('empty', undefined);
router.has('empty'); // true
router.get('empty'); // undefined
router.has('missing'); // false
router.get('missing'); // null, from the original Dart API
identity(undefined); // undefined
```

The same declarations target native Node-API and Dart Wasm. Objects, functions,
symbols and primitives retain their original JS identity/value on synchronous
and nested payload paths. No payload
property, prototype or `then` is read, and payloads are not cloned, coerced or
invoked by those paths. Root Future results use the standard Promise resolution
described below. A function can be stored as a payload; calling it from Dart belongs to
the separate callback feature.

## Author contract

The default generic binding is a storage/forwarding contract, not general Dart
runtime specialization. Generated Dart instantiates the declaration with a
private carrier type. Business code may store, return or remove that carrier. It must
not use casts, runtime type checks, payload method calls, equality or hash codes
to interpret the original JS value. This is the binding contract for an exported generic declaration, not a
whole-program proof that its implementation follows the rule. The same
requirement applies to external dependencies selected with `ExternalLibrary`;
there is no additional generic configuration.

The generator reads every declared type parameter in Dart declaration order.
Implicit bounds and canonical `Object`/`Object?`
bounds accept the carrier. Other bounds fail at build time. Even a JS null or
undefined payload is a non-null Dart carrier, so an `Object` bound does not
restrict JS payloads to objects or exclude nullish values.

## Presence and TypeScript

Required opaque arguments must be supplied: `identity()` fails before business
code, while `identity(undefined)` succeeds. A required named property follows
the same rule; its own data property must exist. Optional positional and named `T?`
parameters may default to Dart null. Only omission selects that default;
explicit `undefined` and `null` are stored payloads. For named arguments, an
absent property selects the default. Omitting an all-optional options object,
passing `undefined` as that object, or passing `{}` all omit its properties.

An actual Dart null result becomes JS null. There is no extra universal missing
value outside the unrestricted payload set. Use the original API's `has`, tagged
result or not-found error when it needs to distinguish a missing value from a
stored null; bindings do not add presence arguments or change the business API.

Declarations preserve logical type parameters. Mutable classes are invariant,
including when TypeScript's `strictFunctionTypes` is disabled. Optional positional
payloads use supplied-prefix overloads so `Router<string>.optional(undefined)`
does not become valid merely because the parameter can be omitted. Strict null
checking is part of the TypeScript contract. Named constructors introduce their
own inferred type parameters and return the corresponding generic class.

Optional named payloads use standard TypeScript properties such as
`value?: T | null`, including when several share an options object. Enable
`exactOptionalPropertyTypes` with strict null checking to reject a present
`undefined` when it is not part of `T`. Without that flag, TypeScript's ordinary
optional-property rules permit explicit `undefined`; the generated declaration
does not block the whole options object. Runtime presence remains exact under
either configuration:

```dart
@NAPI()
T? choose<T>({T? first, T? second, bool useSecond = false}) =>
    useSecond ? second : first;
```

```ts
choose<string>();                            // null
choose<string>({first: 'value'});            // 'value'
choose<string | undefined>({first: undefined}); // undefined
choose<string | undefined>({second: undefined, useSecond: true}); // undefined
// With exactOptionalPropertyTypes, this is a type error:
choose<string>({first: undefined});
```

The entire options object may be omitted only when every named parameter is
optional. Required named properties retain their payload type without an added
`undefined`, under either compiler setting. Ordinary optional scalar properties
still allow `undefined` because it selects their Dart default.

## Ownership

Native carriers own strong JS references. Unreachable acyclic carriers release
those references automatically. A Dart root retains its payload even when its
JS wrapper is collected; later wrapper readoption preserves the payload.
Clearing a stored field or removing a map entry permits carrier collection.

Authors must break native cross-heap cycles. For example, a payload pointing
back to the Router wrapper needs `router.clear()` before the author drops its
last usable reference. Ordinary field/map clearing is sufficient; business code
does not call the carrier's private release operation. No disposal method is
added to ordinary classes, and GC never runs business cleanup. Wasm may collect
more cycles automatically; portable code follows the same explicit ownership
contract. Environment teardown releases remaining native references.

## Current boundaries

Generated bindings support ordinary generic reference classes, top-level generic
functions, direct opaque inputs/results/fields, required and optional named
inputs, optional positional inputs and matching selected generic class references.
Future results may also carry direct opaque payloads, including nullable payloads,
with standard Promise resolution. Future calls retain opaque inputs until the
Dart Future completes and its result is handed to the JS resolver. Waiting
through subsequent JS thenable adoption is the separate resource-lease contract.

Type parameter names use the current TypeScript-compatible ASCII identifier
subset: a letter or underscore followed by letters, digits or underscores,
excluding `$`, reserved words and the standalone wildcard `_`. A type parameter
must not shadow its class's exported name or a referenced class's exported name.

Direct opaque leaves in explicit `JsArray<T>` and `JsMap<K, V>` handles preserve
the original JS values on access. Extracted values remain retained independently
of their source slots; opaque Map keys keep JS identity. These handles do not copy
or interpret their payloads. See [collection ownership](collections.md).

Opaque leaves inside ordinary structural containers, open opaque selected hierarchies,
independent generic member methods and generic resource/value classes remain
unsupported. Concrete or erased specializations
such as `Router<String>` or raw `Router` are not interchangeable with
`Router<T>` under this carrier policy. They receive build diagnostics.

`Future<T>` and `Future<Generic<T>>` hand the converted root value to a genuine
Promise resolver. It reads `then` and adopts callable thenables, including a
selected generic class's field/getter or later JavaScript wrapper mutations.
The fulfillment value can therefore differ from the original payload; getter
errors reject with their exact thrown value. TypeScript describes the resolved
value, including callable/non-callable union branches. Synchronous opaque values
and values nested inside returned containers retain their ordinary identity.
See [the Promise contract](futures.md#promise-resolution-and-identity).

Setter-only properties read `undefined`. Their declarations also include getters
that compatible selected views may contribute, including through an unselected
Dart implementation. Such ambiguous reads use a conservative union; a getter
with unknown generic arguments can make the read and Promise result `unknown`.
Without a compatible getter view, the read remains exactly `undefined`, so a
setter-only `then` preserves the wrapper. Static setter-only reads are always
`undefined` because static members do not participate in view composition.

The unsupported generic combinations above remain tracked in the broader
generics/composition issues, including #110.

## Validation and cost

The optional named follow-up passes 15 fresh-process opaque scenarios and eight
TypeScript configurations for each backend on Node 24.19.0/26.11.1. Annotated and
external selections cover multiple optional fields, required/optional mixtures,
constructors, methods, Future inputs/results, exact reflection failures and
retention/release after field clearing or Future settlement. TypeScript tests
cover both literal and aliased options under both exact-optional settings. Full
native/Wasm consumers, 538 Dart tests (one Windows-only local skip) and 23 Wasm
resource tests pass. It reuses the existing ABI14 bundle; no runtime rebuild or
additional host-value operation is required.

The standard Promise-resolution follow-up passed 13 fresh-process opaque scenarios
and eight TypeScript configurations per backend on Node 24.19.0/26.11.1. Both full
consumer suites, 528 Dart tests (one Windows-only skip) and 23 Wasm resource tests
passed. The resource suite additionally verifies opaque thenable settlement and
cleanup ordering. That update used ABI13. The counts and costs below record the
original synchronous generic-payload delivery.

Generated annotated and external-selection packages were built, packed, moved
and installed into fresh consumers after deleting their business/build sources.
Native and Wasm each passed Node 24.19.0 and 26.11.1: 25 payload categories,
10 fresh-process lifetime/presence scenarios, and eight TypeScript 7.0.2 modes
(NodeNext/Bundler, exact optional properties and strict function types on/off).
The complete existing native/Wasm consumers, 497 Dart tests and 23 Wasm resource
kernel tests passed; one Windows-only Dart test was skipped on this macOS host.
Both backends remain coupled to the qualified Dart 3.13.5 compiler. Current native
builds require the ABI15 (57 slots) macOS arm64 bundle described in
[native.md](native.md); the complete consumer matrix has also passed with ABI13.
ABI14 additionally exercises hostile and revoked callable Proxies, extending the
payload matrix to 27 categories and checking the direct function-reference path
without reading payload properties or invoking functions.
The original validation and measurements below used ABI12, which introduced the
owned-value kernel.

A local unchanged scalar/Counter sample before and after this generator change
remained 6,588,276 bytes, with identical loader, declarations, bridge and runtime.
The AOT size was unchanged, though its bytes differed. A/A and three balanced
ABBA rounds on each Node version measured ordinary function/getter/method median
changes from -1.08% to +0.50%; constructor changes were +2.59% (Node 24) and +0.38%
(Node 26), with mixed individual pairs. These measurements do not establish zero
regression or portability to another host.

For the generated `identity`, `Router.set` and `Router.get` paths, a separate
A/A plus three balanced ABBA comparison measured 100,000 calls per operation,
with event-loop turns every 1,000 calls. The same payload object was retained:

| Local median per call | Native Node 24 / 26 | Wasm Node 24 / 26 |
| --- | --- | --- |
| `identity(payload)` | 1,451 / 1,411 ns | 12.5 / 11.8 ns |
| `router.set(key, payload)` | 1,795 / 1,849 ns | 74.7 / 63.3 ns |
| `router.get(key)` | 1,236 / 1,217 ns | 61.8 / 48.8 ns |

This measures these small operations on macOS arm64, not a general application
speedup or a memory bound. Native creates an owned reference for accepted payload
inputs; Wasm carries the externref directly. The native measurement used the same
opaque implementation before adding unrelated type-name hygiene fixture exports.
