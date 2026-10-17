# Opaque generic payloads

Select generic parameters explicitly when Dart stores and forwards JavaScript
values without interpreting them:

```dart
@NAPI(opaque: ['T'])
class Router<T> {
  final Map<String, T> _values = {};
  Router();
  void set(String key, T value) => _values[key] = value;
  T? get(String key) => _values[key];
  bool has(String key) => _values.containsKey(key);
  void remove(String key) => _values.remove(key);
  void clear() => _values.clear();
}

@NAPI(opaque: ['T'])
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
symbols and primitives retain their original JS identity/value. No payload
property, prototype or `then` is read, and payloads are not cloned, coerced or
invoked. A function can be stored as a payload; calling it from Dart belongs to
the separate callback feature.

## Author contract

`opaque` is an explicit storage/forwarding policy, not general Dart runtime
specialization. Generated Dart instantiates the declaration with a private
carrier type. Business code may store, return or remove that carrier. It must
not use casts, runtime type checks, payload method calls, equality or hash codes
to interpret the original JS value. A generic signature alone does not prove
that a declaration follows this rule; the same requirement applies to external
dependencies selected with `ExternalLibrary` and `NAPI(opaque: ...)`.

Select every declared type parameter by its Dart name. The annotation list does
not change parameter order. Implicit bounds and canonical `Object`/`Object?`
bounds accept the carrier. Other bounds fail at build time. Even a JS null or
undefined payload is a non-null Dart carrier, so an `Object` bound does not
restrict JS payloads to objects or exclude nullish values.

## Presence and TypeScript

Required opaque arguments must be supplied: `identity()` fails before business
code, while `identity(undefined)` succeeds. A required named property follows
the same rule; its own data property must exist. Optional positional `T?`
parameters may default to Dart null. Only omission selects that default;
explicit `undefined` and `null` are stored payloads.

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

The first generated slice supports ordinary generic reference classes,
top-level generic functions, direct opaque inputs/results/fields, required
named inputs, optional positional inputs and matching selected generic class
references. A Future with a non-opaque result can retain opaque inputs until
the Dart Future completes and its result is handed to the JS resolver. Waiting
through subsequent JS thenable adoption is the separate resource-lease contract.

Type parameter names use the current TypeScript-compatible ASCII identifier
subset: a letter or underscore followed by letters, digits or underscores,
excluding `$`, reserved words and the standalone wildcard `_`. A type parameter
must not shadow its class's exported name or a referenced class's exported name.

Optional named opaque parameters, opaque leaves inside structural containers,
generic selected hierarchies, independent generic member methods and generic
resource/value classes remain unsupported. Concrete or erased specializations
such as `Router<String>` or raw `Router` are not interchangeable with
`Router<T>` under this carrier policy. They receive build diagnostics.

`Future<T>` with an opaque result is also unsupported: a genuine JS Promise
observes and assimilates thenables, which conflicts with unrestricted identity
and zero payload inspection. This restriction does not prohibit storing Promise
objects as synchronous opaque payloads. These remaining combinations stay
tracked in #125 and the broader generics/composition issues.

## Validation and cost

Generated annotated and external-selection packages were built, packed, moved
and installed into fresh consumers after deleting their business/build sources.
Native and Wasm each passed Node 24.19.0 and 26.11.1: 25 payload categories,
10 fresh-process lifetime/presence scenarios, and eight TypeScript 7.0.2 modes
(NodeNext/Bundler, exact optional properties and strict function types on/off).
The complete existing native/Wasm consumers, 497 Dart tests and 23 Wasm resource
kernel tests passed; one Windows-only Dart test was skipped on this macOS host.
Both backends remain coupled to the qualified Dart 3.13.5 compiler; native used
the existing ABI12 macOS arm64 bundle described in [native.md](native.md).

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
