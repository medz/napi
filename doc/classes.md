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
private JavaScript dependency. Required top-level functions retain their direct
Wasm function exports. Native packages expose the same class shape through their
automatic ESM entry and Node-API bridge.

The implemented slice includes a concrete, non-generic reference class's public
unnamed generative constructor, own instance/static methods, fields, explicit
accessors, readonly fields, renaming and exclusions. Parameters and results use
the strict scalar and default rules, including nullable values, arbitrary BigInt,
UTF-16 strings, safe integer numbers and double special values. Named constructor
parameters use the ordinary options-object policy. Void methods return
`undefined`. Invalid input fails before business code; output validation occurs
after business code, so a failed output check does not undo Dart mutations.

Extracted instance methods need their original receiver: `method.call(counter)`
works; calling a detached method without a receiver fails. Forged prototypes,
other classes, Proxy wrappers and independently loaded module instances fail
before invoking Dart. Method/accessor functions are nonconstructible. Ordinary
JavaScript `.length` reflects the generated parameter mapping: required
positional count, or zero for an optional/named callable; setters have length one.

Each Wasm wrapper directly retains its externalized Dart object in a private
field. There is no global strong object registry and no finalizer that calls a
business cleanup method. A reachable wrapper keeps the Dart object alive; normal
GC can collect both after the wrapper becomes unreachable. Native wrappers use
the corresponding retained-object cleanup described in [native builds](native.md).
Repeated imports of the same module graph, including npm root/direct-Wasm
subpaths, share constructors. A copied complete Wasm graph has independent class
brands and Dart state; a query suffix on only the facade is not an independent
graph because its dependencies may still be shared.

Class arguments/results, repeated-return wrapper identity, named/factory
constructors, generic specialization, structural members, value/resource policies
and async APIs remain unsupported and produce build diagnostics. JavaScript
inheritance relationships are not generated: only the selected class's own public
members are exposed. This slice does not complete #123's full identity contract.

`dart run tool/class_fixture.dart` verifies annotated and unannotated external
classes, a class-only module, an independent Dart build project, an npm tarball
installed after removing the original business/build/package directories,
TypeScript NodeNext/Bundler, whole-graph isolation, bounded GC and normal/terminated
Workers. The shared class contract is also run by `tool/native_verify.dart`.
Tested with Dart 3.13.5, Node 24.19.0/26.11.1 and TypeScript 7.0.2; native execution
is currently qualified only on macOS arm64.
