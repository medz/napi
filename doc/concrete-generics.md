# Concrete generic exports

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

Constructors, named constructors, fields and methods use the selected Dart type
arguments, including inside nested containers, nullable types and
selected reference classes. Dart bounds and F-bounds remain Dart constraints;
invalid aliases fail at their source locations before output is written.
An alias's spelling is not its identity: parameters spelled `Cell<int>` or with
another unselected equivalent typedef refer to the same selected `IntCell`.

## Partially open class aliases

An alias can fix some Dart arguments while retaining opaque payload parameters:

```dart
class Pair<A, B> {
  Pair(this.first, this.second);
  A first;
  B second;
}

@NAPI()
typedef IntPair<T> = Pair<int, T>;
```

`new IntPair(1, payload)` uses a real Dart `int` for `first` and preserves the
original JS payload in `second`. TypeScript exposes `IntPair<T>`; `T` follows the
[opaque storage contract](opaque.md#author-contract), rather than selecting a
real Dart specialization. `ExternalClass('IntPair')` selects the same API.
Reference, resource and value-class policies use the existing ownership and
conversion rules.

Parameters may be reordered or repeated, for example
`typedef Flipped<X, Y> = Triple<Y, int, X>`. Every alias parameter must appear as
a direct argument of the selected class, optionally nullable. For example,
`typedef NullablePair<T> = Pair<int, T?>` exposes a `T | null` payload field;
omitting a required payload still fails, and explicit `undefined` remains an
opaque value. The nullable shape belongs to this selected alias: an ordinary
`Pair<int, T>` handle cannot acquire its wider writable view.

Nested uses such as `List<T>`, and unused parameters, remain diagnosed. Remaining
parameters accept the ordinary opaque bounds. A selected ancestor alias must
retain the existing bijective mapping between its remaining opaque parameters
and the child's parameters.

## Concrete callable exports

A public top-level `const` can select real type arguments for a top-level
function or static method, using the same annotation and external selector:

```dart
T read<T extends num>(T value, {int count = 7}) => value;
String kind<T>() => T == int ? 'int' : 'other';

@NAPI()
const readInt = read<int>;

@NAPI()
const intKind = kind<int>;
```

JavaScript calls `readInt(3)` and `intKind()`; the latter returns `'int'` because
Dart executes the actual `int` specialization. `ExternalFunction('readInt')`
selects the same callable without annotating the source. `@NAPI(bigint: true)`
applies the existing integer policy to the specialized signature.

The initializer must directly name a top-level function or static method with
explicit closed type arguments. The selected const can be reexported, declared
in a part, or target a private function or imported static method. The generated
call uses that public const. Its resolved initializer supplies parameter names,
Dart defaults and result types, including nested types and typedef arguments.
An explicit function type or typedef on the const is accepted only when its
signature matches the initializer; widening or erasing it is diagnosed.

Mutable and `final` variables, inferred instantiations, alias chains, closures,
constructor tear-offs and bound instance methods remain diagnosed. Arguments
containing `dynamic` or open generic function types are also unsupported.
Ordinary open generic methods use the [opaque payload contract](opaque.md#generic-methods); automatic
concrete callable specialization is not supported.

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

@NAPI(classPolicy: ClassPolicy.value)
typedef IntBox = Box<int>;

@NAPI(classPolicy: ClassPolicy.value)
typedef TextBox = Box<String>;
```

Both aliases have independent input/output schemas. Input materialization calls
`IntBox(...)` or `TextBox(...)` with the actual Dart type arguments. Named and
factory constructors, `valueFields`, member renames and exclusions follow the
[existing value contract](values.md). `ExternalClass('IntBox', config:
NAPI(classPolicy: ClassPolicy.value))` selects the same
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
`Node<List<int>>` is diagnosed, not instantiated automatically. Each
specialization resolves its input constructor from the selected Dart declaration:
an explicitly selected public constructor or factory takes precedence, followed
by the public unnamed constructor, or a sole public named constructor or factory.
A specialization without an unambiguous callable
constructor is output-only. Defaults, bigint policy, copy semantics and whole-root
validation before construction remain unchanged.

## Supported shapes and limits

Class exports support non-null closed aliases and partially open aliases with
direct opaque arguments. Callable consts require explicit closed specializations.
Arguments containing `dynamic` or generic function types remain diagnosed even
when Dart considers the surrounding alias closed. [Open opaque generics](opaque.md)
use a separate storage/forwarding contract. Selecting an original class and one of its
aliases together is rejected, as is selecting multiple aliases for the
same canonical specialization. Selected hierarchies support ordinary classes,
class aliases and [bijective opaque parameter mappings](opaque.md#reference-inheritance).
Other open ancestor mappings remain diagnosed. Reference selections
that Dart type tests cannot distinguish, such as `Marker<void>` with `Marker<Object?>`, are also rejected;
value projections do not use that runtime classification.

Native `.node` and Dart Wasm share these substitutions and declarations. Future returns
use standard Promise resolution. Stream values keep their usual identity and
retention rules. See the [compatibility requirements](../README.md#verify).
