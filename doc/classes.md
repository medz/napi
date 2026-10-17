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

Constructors, methods and property access execute in Dart. The generated Wasm
facade exports each class as an immutable externref global imported from its
private JavaScript dependency. Required top-level scalar functions retain their direct
Wasm function exports, including required List/Map/Dictionary/record arguments containing class
references; direct reference-valued calls use callable globals. Native packages expose the same class shape through their
automatic ESM entry and Node-API bridge.

The implemented slice includes non-generic reference classes, direct class
arguments/results, instance/static methods, fields, explicit accessors,
readonly fields, renaming and exclusions. Unnamed generative and factory
constructors use `new Counter(...)`; a cached Dart factory can return an existing
JS wrapper. Named constructors and factories become static methods, for example
`Counter.named(...)`, with renaming applied. A class without a selected unnamed
constructor exposes a private TypeScript constructor and rejects public `new`.
Abstract classes can expose factory constructors backed by a concrete Dart object.

Parameters/results use strict scalar, selected reference, [value-class](values.md) or nested List/Map/Dictionary/record
types, including nullable nodes. Containers are cloned while their reference
leaves preserve live wrapper identity. This also applies to constructors, methods,
fields and accessors. Optional reference/structural parameters may default to null; omission
and `undefined` apply that default. Required nullable references still require a
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
the class constructor itself remains constructible. Native loaders install
concise JavaScript forwarders around the generated callbacks to provide this
shape, preserving receivers, argument counts and property attributes. Accessor
function names use the standard `get name` / `set name` spelling. Ordinary
JavaScript `.length` reflects the generated parameter mapping: required
positional count, or zero for an optional/named callable; setters have length one.

A reachable wrapper retains its Dart object. Repeated returns of that object
reuse the same reachable wrapper (`===`), while distinct objects remain distinct.
The Wasm cache uses a weak Dart-object key and weak JS-wrapper value. Native uses
a weak Dart identity association and a zero-count Node-API reference; its live
wrapper owns a separate retained-object lease. When Dart keeps the object but JS
drops its wrapper, the wrapper can be collected and a later return creates a new
one without running a business constructor. Old finalizers cannot release the
new lease. No identity cache permanently roots ordinary unreachable objects, and
GC never calls a business disposal method. Wasm registers its private reference
converters automatically when classes are defined; structural traversal uses the
same cache and brands, without consumer initialization. See [native builds](native.md).

On first exposure, the runtime checks actual Dart membership and chooses the
unique most-specific selected reference class. Returning a Child as Base first
therefore creates the same Child wrapper as returning it as Child first; subsequent
calls and collection/readoption reuse that choice. Classification runs once per
identity claim, with one check per selected reference class; ordinary receiver
checks use the cached class's membership set. A base factory returning a child
adopts the child without invoking its constructor again.

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

Repeated imports of the same module graph, including npm root/direct-Wasm
subpaths, share constructors. A copied complete Wasm graph has independent class
brands and Dart state; a query suffix on only the facade is not an independent
graph because its dependencies may still be shared.

Generic specialization, resource policies
and async APIs remain unsupported and produce build diagnostics. Non-null Dart
object defaults are also rejected. An object implementing unrelated selected
public types without a unique most-specific selected class currently raises
TypeError on first exposure. Compatible composite interface views remain work
for #123; this slice must not be treated as complete polymorphic class support.

`dart run tool/class_fixture.dart` verifies annotated and unannotated external
classes, a class-only module, an independent Dart build project, an npm tarball
installed after removing the original business/build/package directories,
TypeScript NodeNext/Bundler, whole-graph isolation, twelve collect/readopt cycles,
Dart weak-reference collection under bounded allocation pressure, nested reference
identity and six container-held collect/readopt cycles, structural class members,
canonical Base/Child/interface views, partial accessor overrides, JS subclasses,
custom construction targets and six hierarchy collect/readopt cycles,
and normal/terminated Workers. The shared class contract is also run by
`tool/native_verify.dart`.
Tested with Dart 3.13.5, Node 24.19.0/26.11.1 and TypeScript 7.0.2; native execution
is currently qualified only on macOS arm64.

Frozen old/new single-class measurements on these Node versions used separate
A/A samples and three balanced AB/BA rounds. The canonical implementation added
1,989 bytes (1.70%) to the small Wasm package, including 251 bytes of core Wasm;
the native package grew 1,886 bytes. Wasm getter medians rose from 19.435 to
20.562 ns on Node 24 and 18.891 to 19.693 ns on Node 26, consistently slower in
paired samples. Other Wasm call changes ranged from -15.03% to +5.24%; native
changes ranged from -1.06% to +2.29%. These are local observations, not a general
speed or no-regression claim. Constructor A/A noise reached about 25%; its
200,000 allocations occurred in one JS turn, so WeakRef retention and measured
RSS do not establish long-term memory bounds. Large class hierarchies were not
benchmarked. The ordinary callback path reuses the cached canonical class;
first-exposure work grows with the selected class set.
