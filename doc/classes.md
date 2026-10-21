# Reference classes

Both targets generate real JavaScript constructors backed by Dart objects:

```dart
@NAPI()
class Counter {
  int value;
  Counter([this.value = 0]);
  int increment([int amount = 1]) => value += amount;
}
```

```js
import {Counter} from './module.wasm'; // or the assembled npm package
const counter = new Counter();
counter.increment(undefined); // 1
counter.value = 40;
counter.increment(2); // 42
```

Constructors, methods and property access execute in Dart. Native and Wasm
packages expose the same JavaScript class shape and initialize on import.

Supported classes include non-generic reference classes and explicitly
selected [opaque generic classes](opaque.md), direct class
arguments/results, instance/static methods (including inherited opaque generic methods),
fields, explicit accessors,
readonly fields, renaming and exclusions. Unnamed generative and factory
constructors use `new Counter(...)`; a cached Dart factory can return an existing
JS wrapper. Named constructors and factories become static methods, for example
`Counter.named(...)`, with renaming applied. A class without a selected unnamed
constructor exposes a private TypeScript constructor and rejects public `new`.
Abstract classes can expose factory constructors backed by a concrete Dart object.

Parameters/results use strict scalar, selected reference, [value-class](values.md) or nested List/Map/Dictionary/record
types, including nullable nodes. Containers are cloned while their reference
leaves preserve live wrapper identity. This also applies to constructors, methods,
fields and accessors. Optional references may default to null or a
[const object](arguments.md). Structural parameters support
the same constants in their containers. Omission
and `undefined` apply the default. Required nullable references still require a
value, with `null` accepted. Named parameters use the ordinary options-object
policy. Void methods return `undefined`. Invalid input fails before business code;
output validation happens after business code and does not undo Dart mutations.

Extracted instance methods need a genuine compatible receiver: `method.call(counter)`
works; calling a detached method without a receiver fails. A selected subtype can
be passed to its selected base or interface and can borrow their methods.
Forged prototypes, unrelated classes, Proxy wrappers and independently loaded module instances fail
before invoking Dart. Method/accessor functions are nonconstructible: they have
no own `prototype` and cannot serve as `Reflect.construct`'s `newTarget`, even
after `bind`. Named constructors exposed as static methods follow this rule;
the class constructor itself remains constructible. Accessor
function names use the standard `get name` / `set name` spelling. Ordinary
JavaScript `.length` reflects the generated parameter mapping: required
positional count, or zero for an optional/named callable; setters have length one.

A reachable wrapper retains its Dart object. Repeated returns of that object
reuse the same reachable wrapper (`===`), while distinct objects remain distinct.
When Dart keeps the object but JS drops its wrapper, the wrapper can be collected
and a later return creates a new
one without running a business constructor. No identity cache permanently roots
ordinary unreachable objects, and GC never calls a business disposal method.
Direct and nested reference conversions share the same identity and brands.

That weak identity cache does not collect a cycle created by a separately owned
native JS value. For example, a Dart object storing a JS payload that points back
to its wrapper must clear that payload or otherwise break the ownership cycle.
The [opaque ownership contract](opaque.md#ownership) applies to these stored
payloads; ordinary acyclic classes retain automatic
collection and do not need a new disposal API.

On first exposure, the runtime checks actual Dart membership and chooses the
unique most-specific selected reference class when one exists. Returning a Child as Base first
therefore creates the same Child wrapper as returning it as Child first; subsequent
calls and collection/readoption reuse that choice. A base factory returning a child
adopts the child without invoking its constructor again.

An object implementing compatible unrelated selected interfaces keeps one
wrapper with their combined instance methods and properties. This default
wrapper has a private prototype inheriting `Object.prototype`, so its
`constructor` is `Object` and it does not pass those interfaces' `instanceof`
tests. Actual Dart membership accepts the wrapper as each interface, including
explicitly borrowed methods. The complete surface is independent of which
interface returned it first. A unique selected concrete class still uses its
public prototype instead. TypeScript does not invent inheritance between the
unrelated interface declarations.

Composition uses the most-specific matched views and merges getter/setter
halves. Overridden ancestor declarations do not replace their selected child's
defaults. A repeated JS name must refer to the same Dart member with compatible
parameter/result conversions and call mapping; defaults must agree whenever
both declarations allow omission. Conflicts raise `TypeError` with the output
path when that combination is first exposed. Merely selecting two conflicting
interfaces does not reject unrelated objects or the entire module. Different
export aliases can retain their separate call contracts.

Wrapper collection/readoption and failed-output rollback follow the same rules
for composite objects as for concrete classes.

Instance prototypes follow the nearest selected Dart superclass, skipping
unselected intermediate ancestors. Selected interface members are available on
compatible concrete wrappers, but interfaces do not create extra prototype chains
or redefine `Symbol.hasInstance`. Actual Dart membership, rather than
`instanceof`, controls parameter and receiver acceptance. Getter/setter halves
are inherited separately and installed as complete descriptors. Static members
and named constructors do not inherit. TypeScript describes these instance
relationships without adding inherited static members.

An explicitly excluded override, incompatible rename, conversion or call mapping
that breaks a selected ancestor's contract produces a build diagnostic. Known
inherited implementations in unselected intermediate classes are checked too;
a covariant parameter narrowing cannot bypass the selected ancestor's input
contract. A method overriding a void method can expose its own return value,
while explicitly borrowing the base method still returns `undefined`. Defaults
belong to the selected declaration: a child's own override uses its selected
defaults, while explicitly borrowing a base method uses the base defaults.
An unselected private override can have different Dart defaults; the generated
binding still uses the selected declaration's values, including independent
positional `undefined` holes. This policy does not reflect runtime override
defaults dynamically.

Ordinary JavaScript subclasses and custom `Reflect.construct` targets retain
their supplied prototype and receiver. They can use JS private fields and call
`super.method()`. A factory's already reachable wrapper takes precedence over a
later `newTarget`. A custom prototype need not satisfy the public constructor's
`instanceof` test to hold a genuine Dart reference.
For a composite object, an explicit custom prototype can hide the unrelated
interfaces' methods; borrowing those interfaces' methods remains valid.

Repeated imports of the same module graph, including npm root/direct-Wasm
subpaths, share constructors. A copied complete Wasm graph has independent class
brands and Dart state; a query suffix on only the facade is not an independent
graph because its dependencies may still be shared.

Ordinary methods and getters may return [Futures](futures.md). A selected
synchronous call contract cannot silently become Promise-returning through an
override; `Future<void>` remains a Promise contract, not synchronous result discard.
[Resource classes](resources.md) additionally share state and operation leases;
their selected cleanup maps both `void` and `Future<void>` to `Promise<void>`.
[Finite concrete aliases](concrete-generics.md) and [explicit cooperative
cancellation](cancellation.md) are supported. Other generic specializations are
diagnosed; an abort does not preempt arbitrary Dart execution.
[Typed callback inputs](callbacks.md) and [Stream results](streams.md) use their
documented supported signatures; other combinations produce build diagnostics.
Object defaults without a usable public constructor or const binding are rejected.
A composite must have
a selected operation whose call contract satisfies every view sharing that JS name; the compiler
does not synthesize a new overload or union conversion from incompatible
operations.

## TypeScript reference identity

Reference class declarations carry a private, declaration-only marker for each
selected class. Structurally identical classes and lookalike object literals do
not satisfy each other's handle types. The marker adds no JavaScript property.
Instance-only inheritance declarations also inherit the ancestor markers, so
selected children remain assignable to their selected bases and interfaces.
Structural value classes retain their ordinary structural TypeScript types.
