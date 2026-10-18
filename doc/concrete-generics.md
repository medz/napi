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

A selected concrete reference class is an invariant JavaScript handle. Its TypeScript
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

## Concrete inheritance

Selected ordinary classes and concrete aliases can extend or implement other
selected concrete instances. The resolved arguments must match the selected
ancestor exactly, including through unselected intermediate classes:

```dart
class Child<T> extends Cell<T> {
  Child(super.value);
  @override
  Child<T> self() => this;
}

@NAPI()
typedef IntChild = Child<int>;
```

With `IntCell` selected above, `new IntChild(1)` also has the `IntCell` handle
membership and inherits its selected instance members. Its `self()` retains the
same wrapper. `Child<double>` instead inherits the selected `DoubleCell` view;
these specializations cannot exchange wrappers just because both fields use
TypeScript `number`. Nested substitutions such as `Child<int>` extending
`Cell<List<int>>` retain the full ancestor instance.

JavaScript prototypes follow the nearest selected superclass. Selected interface
members and input acceptance follow Dart membership, while interfaces do not
add an `instanceof` relationship or change `Symbol.hasInstance`. Static members
and named constructors do not inherit. Own overrides retain their defaults;
borrowing a parent's method keeps that parent's omission/default contract.
External member overrides remain scoped to the selected ancestor alias.

Dart covariance does not create another writable ancestor view. An `IntChild`
extending `Cell<int>` cannot be passed to `NullableCell`, even though Dart's
`is Cell<int?>` test succeeds. Selecting a wider `Child<int?>` beside it does not
remove the narrower object's valid `IntCell` membership. The same rules apply
when an unselected implementation combines the child with unrelated interfaces,
or a selected ordinary descendant exposes an exact ancestor through a wider
selected generic intermediate. Classification retains every valid selected
ancestor view in these combinations. An unselected narrower implementation
accepted through a selected wider child retains that child's ancestor membership
and cleanup policy; a raw narrower Dart type test does not remove that ancestor.
Dart's covariant write checks still apply to the underlying object. Composite
views that require different concrete instances of the same ancestor are rejected
before exposing a wrapper, even when the conflicting ancestors are inherited
through unrelated selected children. Multiple paths to the same ancestor remain
compatible.

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
Selected resource children retain the same operation leases and share compatible inherited cleanup policies. A child
explicitly selected with the resource policy still names an own cleanup method; different cleanup methods, parameter
contracts or omission defaults that would assign incompatible inherited policies
are diagnosed before generation. Ordinary selected descendants inherit the
ancestor's resource cleanup and leases without repeating the resource annotation.

## Structural value aliases

A concrete alias can use the existing value policy, including an explicit input
constructor and parameter-to-field mapping:

```dart
class Box<T> {
  final T value;
  final Box<T>? next;
  Box(this.value, {this.next});
}

@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
typedef IntBox = Box<int>;

@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
typedef TextBox = Box<String>;
```

Both aliases have independent input/output schemas. Input materialization calls
`IntBox(...)` or `TextBox(...)` with the actual Dart type arguments. Named and
factory constructors, `valueFields`, member renames and exclusions follow the
[existing value contract](values.md). `ExternalClass('IntBox', config:
NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new'))` selects the same
mapping without changing the business source.

The public names are TypeScript data types; no JavaScript constructor or nominal
handle brand is generated. Output projects the declared schema into a fresh
plain object. A value alias and a reference alias with different arguments can
coexist; each use selects its own conversion, and a plain object never becomes a
reference handle. The reference-only runtime classification rules above do not
restrict structural projections.

Nullable uses, nested containers and finite recursive schemas retain each
specialization. Every referenced value instance must be selected: `Box<Box<int>>`
requires a selected `Box<int>` schema. An unselected expanding instance such as
`Node<List<int>>` is diagnosed, not instantiated automatically. Omitting the
constructor makes that specialization output-only, even if another alias of the
same original class permits inputs. Defaults, bigint policy, copy semantics and
whole-root validation before construction remain unchanged.

## Current scope

This slice covers non-null, closed aliases of reference, resource and value classes.
Arguments containing `dynamic` or generic function types remain diagnosed even
when Dart considers the surrounding alias closed. It preserves existing [open opaque generics](opaque.md). Selecting an open class and
one of its concrete aliases together, multiple aliases for the same canonical
specialization remain diagnosed. Selected hierarchies require ordinary classes
or closed aliases; open opaque hierarchies remain diagnosed. Reference selections
that Dart type tests cannot distinguish, such as `Marker<void>` with `Marker<Object?>`, are also rejected;
value projections do not use that runtime classification. Generic functions and
methods that require real type arguments remain separate work in [#126](https://github.com/medz/napi/issues/126).

Native `.node` and Dart Wasm share the substitutions and declarations; each
backend keeps its existing identity and lifetime implementation. Future returns
use standard Promise resolution. Stream values keep their usual identity and
retention rules. Compiler/runtime coupling remains the pinned Dart 3.13.5 setup
documented in [native](native.md) and [architecture](architecture.md).
