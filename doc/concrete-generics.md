# Concrete generic class aliases

Select a finite set of ordinary Dart aliases when business logic needs real Dart
type arguments. The existing annotation and external class selector both work:

```dart
class Cell<T> {
  T value;
  Cell(this.value);
  bool get isInt => T == int;
  Cell<T> self() => this;
}

@NAPI()
typedef IntCell = Cell<int>;

@NAPI()
typedef DoubleCell = Cell<double>;
```

```js
const integer = new IntCell(7);
const decimal = new DoubleCell(1.5);
integer.isInt; // true: the business object really is Cell<int>.
decimal.isInt; // false
integer.self() === integer; // true
```

The external equivalent is `ExternalClass('IntCell')` and
`ExternalClass('DoubleCell')`. Each selection has its own member configuration;
renaming or excluding a member on one alias does not change the other. External
selection retains its existing rule of ignoring source annotations.

Constructors, named constructors, fields and methods use Analyzer's resolved
substitutions. These include nested containers, nullable type arguments and
selected reference classes. Dart bounds and F-bounds remain Dart constraints;
invalid aliases fail at their source locations before output is written. No
runtime type descriptors, string type names or new annotation options are needed.
An alias's spelling is not its identity: parameters spelled `Cell<int>` or with
another unselected equivalent typedef refer to the same selected `IntCell`.

## Handle identity and covariance

A selected concrete class is an invariant JavaScript handle. Its TypeScript
class has a private declaration-only marker, so `IntCell` and `DoubleCell` cannot
be interchanged even though their numeric fields both map to TypeScript `number`.
Integer precision and fractional-value checks remain runtime checks.

Dart itself is covariant: `Cell<int>` also satisfies `Cell<int?>`. Bindings select
the most specific matching declared specialization and do not grant that object
the wider alias's writable JavaScript surface. A `Cell<int>` cannot safely accept
`null` through a `Cell<int?>.value` setter. Passing an `IntCell` to a `NullableCell`
parameter therefore fails; returning an actual `Cell<int>` from an export declared
as `NullableCell` also fails when both specializations are selected. A genuinely
constructed `Cell<int?>` accepts `null`.

Unselected subclasses retain the selected alias's handle when they match it.
Classification uses Dart type tests, never business getters or an overridable
`runtimeType`. These tests distinguish the selected candidates; they do not
extract arbitrary runtime type arguments. An unselected stricter subtype can
still match a selected alias, and its Dart covariant write checks still apply. If an object matches two incomparable specializations of the same
class, conversion fails rather than constructing an ambiguous wrapper. Distinct
ordinary interface views retain their existing composition rules.

## Resource aliases

Concrete aliases can select the existing resource policy:

```dart
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
typedef IntSession = Session<int>;
```

The external equivalent is `ExternalClass('IntSession', config:
NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close'))`. Cleanup names an own
public method on the original class. Its signature is checked after concrete
substitution; `Future<T>` is a valid cleanup result when the selected `T` is
`void`. Both synchronous and asynchronous cleanup expose `Promise<void>`.

Resource aliases preserve the [resource lifecycle](resources.md): one cleanup
completion per object, rejected new operations after closing starts, and leases
for accepted Future and Stream work. A selected wider covariant alias does not
contribute a second cleanup policy to a narrower selected instance. Different
aliases may choose different cleanup methods; classification and cleanup use the
same most-specific selected view. No cleanup runs automatically during GC.

## Current scope

This slice covers non-null, closed aliases of reference and resource classes.
Arguments containing `dynamic` or generic function types remain diagnosed even
when Dart considers the surrounding alias closed. It preserves existing [open opaque generics](opaque.md). Selecting an open class and
one of its concrete aliases together, multiple aliases for the same canonical
specialization, mutually assignable but indistinguishable selections such as
`Marker<void>` with `Marker<Object?>`, concrete value aliases and selected
generic hierarchies
remain diagnosed. Generic functions and methods that require real type arguments
remain separate work in [#126](https://github.com/medz/napi/issues/126).

Native `.node` and Dart Wasm share the substitutions and declarations; each
backend keeps its existing identity and lifetime implementation. Future returns
use standard Promise resolution. Stream values keep their usual identity and
retention rules. Compiler/runtime coupling remains the pinned Dart 3.13.5 setup
documented in [native](native.md) and [architecture](architecture.md).
