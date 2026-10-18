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
to interpret the original JS value. The compiler does not analyze the business
implementation for compliance with this contract. The same
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

## Generic methods

Instance and static methods may declare independent opaque parameters using the
same annotation and author contract:

```dart
@NAPI()
class MethodBox<T> {
  T value;
  MethodBox(this.value);
  U echo<U>(U value) => value;
  (T, U) both<U>(U value) => (this.value, value);
  static U staticEcho<U>(U value) => value;
}
```

`new MethodBox('owner').echo(payload)` preserves `payload`; TypeScript infers
its independent `U`. Instance methods can use both class and method parameters;
static methods use only their own parameters. Same-spelled method parameters
shadow the class parameter by Dart declaration scope. Required/optional/named
presence, structural payloads, JS collection handles and Future/Stream results
follow the contracts below. Closed concrete aliases and non-cleanup methods on
non-generic resource classes also support method parameters; resource operations
keep their existing settlement/cancellation leases.

Selected instance methods also work through inheritance, overrides and full-bijection
class parameter mappings. Corresponding method parameters are compared by position,
so `echo<U>(U value)` and `echo<V>(V value)` can share an interface contract. Class
parameters remain separate from method parameters; projected TypeScript names are
renamed only where needed to avoid capture. Borrowing a selected ancestor method
retains that declaration's defaults, even when an override or private mixin has
different defaults.

An object implementing unrelated selected interfaces can expose an equivalent
generic method through both views. Incompatible method arity, presence, bounds or
conversion contracts are rejected; conflicting composite defaults also remain an
error. Actual inherited implementations still undergo Dart subtype validation.
Generic cleanup methods and bare opaque callback payloads remain unsupported.
Callbacks can use JS collection handles whose elements are enclosing opaque
parameters; see [typed callbacks](callbacks.md).

## Reference inheritance

Selected ordinary reference classes may rename or permute all opaque parameters:

```dart
@NAPI()
class Pair<A, B> {
  A first;
  B second;
  Pair(this.first, this.second);
}

@NAPI()
class Reversed<X, Y> extends Pair<Y, X> {
  Reversed(super.first, super.second);
}
```

`new Reversed<string, number>(7, 'value')` is a `Pair<number, string>` view of the
same object. Parent and child methods share the canonical JavaScript wrapper and
payload carriers. TypeScript preserves the parameter order, invariant payload
types and nominal brands. Static members and named constructors belong to their
own exported class.

Every selected generic ancestor must use each child's parameter exactly once,
without nesting or nullable arguments, and have the same parameter count.
This applies through unselected intermediate classes and to selected interfaces.
Own and inherited overrides retain their declaring defaults and argument presence.
Fixed, repeated, omitted, extra or nullable ancestor arguments still receive build
diagnostics. Generic resource/value classes and generic inheritance from a
selected non-generic resource remain unsupported. Use a closed concrete alias for
supported semantic specializations; opaque inheritance does not interpret payloads.

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

## Supported shapes and limits

Generated bindings support ordinary generic reference classes, top-level generic
functions and instance/static generic methods, including inherited instance
methods; direct opaque inputs/results/fields, required and optional named inputs,
optional positional inputs and matching selected generic class references.
Lists, Dictionaries, records and Map values can recursively contain opaque
`T`/`T?` leaves. Structural containers are independently converted; their opaque
leaves preserve the original JS values. `List<Box<T>>` also preserves selected
reference identity, including supported parameter-renaming/permutation inheritance.
`Box<List<T>>` and `Box<T?>` remain unsupported generic specializations.
Future results may also carry direct opaque payloads, including nullable payloads,
with standard Promise resolution. Future calls retain opaque inputs until the
Dart Future completes and its result is handed to the JS resolver. Waiting
through subsequent JS thenable adoption is the separate resource-lease contract.

Type parameter names use the current TypeScript-compatible ASCII identifier
subset: a letter or underscore followed by letters, digits or underscores,
excluding `$`, reserved words and the standalone wildcard `_`. A type parameter
of a class must not shadow that class's exported name; no opaque parameter may
shadow a referenced class's exported name within its scope.

Direct opaque leaves in explicit `JsArray<T>` and `JsMap<K, V>` handles preserve
the original JS values on access. Extracted values remain retained independently
of their source slots; opaque Map keys keep JS identity. These handles do not copy
or interpret their payloads. See [collection ownership](collections.md).

Opaque keys in converted Dart Maps, non-bijective open hierarchies and generic
resource/value classes remain unsupported. Concrete or erased specializations
such as `Router<String>` or raw `Router` are not interchangeable with
`Router<T>` under this carrier policy. They receive build diagnostics.

`Future<T>` and `Future<Generic<T>>` hand the converted root value to a genuine
Promise resolver. It reads `then` and adopts callable thenables, including a
selected generic class's field/getter or later JavaScript wrapper mutations.
The fulfillment value can therefore differ from the original payload; getter
errors reject with their exact thrown value. TypeScript describes the resolved
value, including callable/non-callable union branches. Synchronous opaque values
and values nested inside returned containers retain their ordinary identity.
The same root rule applies to `Future<({T then})>` and `Future<Dictionary<T>>`.
A Dictionary need not contain a `then` key, so its Promise declaration preserves
both the dictionary and adopted-value branches, including recursively adopted
dictionaries. Stream events and values inside
Lists or non-`then` record fields are not deep-awaited.
See [the Promise contract](futures.md#promise-resolution-and-identity).

Native admission failures release newly created opaque carriers. Once business
code starts, ordinary Dart reachability owns them even if the function saves an
input and then throws. Clearing stored containers releases that ownership when
their leaves become unreachable; cross-heap cycles still require the explicit
break described above. `JsArray`/`JsMap` handles may be nested inside copied
containers and value classes. Their adapters follow ordinary Dart reachability:
a later conversion failure does not invalidate a handle already stored by Dart.
Callbacks themselves cannot be nested inside structural containers.

Setter-only properties read `undefined`. Their declarations also include getters
that compatible selected views may contribute, including through an unselected
Dart implementation. Such ambiguous reads use a conservative union; a getter
with unknown generic arguments can make the read and Promise result `unknown`.
Without a compatible getter view, the read remains exactly `undefined`, so a
setter-only `then` preserves the wrapper. Static setter-only reads are always
`undefined` because static members do not participate in view composition.
