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
Wasm function exports; reference-valued calls use callable globals. Native packages expose the same class shape through their
automatic ESM entry and Node-API bridge.

The implemented slice includes non-generic reference classes, direct class
arguments/results, own instance/static methods, fields, explicit accessors,
readonly fields, renaming and exclusions. Unnamed generative and factory
constructors use `new Counter(...)`; a cached Dart factory can return an existing
JS wrapper. Named constructors and factories become static methods, for example
`Counter.named(...)`, with renaming applied. A class without a selected unnamed
constructor exposes a private TypeScript constructor and rejects public `new`.
Abstract classes can expose factory constructors backed by a concrete Dart object.

Parameters/results use strict scalar or selected reference types, including
nullable references. Optional reference parameters may default to null; omission
and `undefined` apply that default. Required nullable references still require a
value, with `null` accepted. Named parameters use the ordinary options-object
policy. Void methods return `undefined`. Invalid input fails before business code;
output validation happens after business code and does not undo Dart mutations.

Extracted instance methods need their original receiver: `method.call(counter)`
works; calling a detached method without a receiver fails. Forged prototypes,
other classes, Proxy wrappers and independently loaded module instances fail
before invoking Dart. Method/accessor functions are nonconstructible. Ordinary
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
GC never calls a business disposal method. See [native builds](native.md).

Repeated imports of the same module graph, including npm root/direct-Wasm
subpaths, share constructors. A copied complete Wasm graph has independent class
brands and Dart state; a query suffix on only the facade is not an independent
graph because its dependencies may still be shared.

Generic specialization, nested structural references, value/resource policies
and async APIs remain unsupported and produce build diagnostics. Non-null Dart
object defaults are also rejected. JavaScript inheritance relationships are not
generated: only a selected class's own public members are exposed, and a wrapper
must match the exact selected public reference type. Returning one Dart object
through different selected public class types raises TypeError instead of
creating multiple wrappers. Canonical cross-type identity remains work for #123;
this slice must not be treated as complete polymorphic class support.

`dart run tool/class_fixture.dart` verifies annotated and unannotated external
classes, a class-only module, an independent Dart build project, an npm tarball
installed after removing the original business/build/package directories,
TypeScript NodeNext/Bundler, whole-graph isolation, twelve collect/readopt cycles,
Dart weak-reference collection under bounded allocation pressure, and normal/terminated
Workers. The shared class contract is also run by `tool/native_verify.dart`.
Tested with Dart 3.13.5, Node 24.19.0/26.11.1 and TypeScript 7.0.2; native execution
is currently qualified only on macOS arm64.
