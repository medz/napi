# Lists, Maps, Dictionaries and records

Both Dart Wasm and native Node-API backends convert nested `List<T>`, `Map<K, V>`,
explicit `Dictionary<V>` and Dart records in both directions.
Every structural node can be nullable. Leaves use the existing strict scalar
rules for `bool`, `String`, `int`, `double` and `BigInt`, or the selected
reference-class contract. [Value classes](values.md) compose as nested structural
shapes with explicit input construction. `@NAPI(bigint: true)` applies recursively to Dart `int`
leaves. Functions, constructors, methods, fields and accessors share this model.

```dart
@NAPI()
List<(String, {List<int?>? values})?> echo(
  List<(String, {List<int?>? values})?> value,
) => value;
```

```ts
echo([{ $1: 'item', values: [1, null] }, null]);
// Array<{ $1: string; values: Array<number | null> | null } | null>
```

| Dart shape | JavaScript / TypeScript shape |
| --- | --- |
| `List<T>` | `Array<T>` |
| `Map<K, V>` | `globalThis.Map<K, V>` |
| `Dictionary<V>` | `{ [key: string]: V }` |
| `(T,)` | `{ $1: T }` |
| `(T, U)` | `{ $1: T; $2: U }` |
| `({T label})` | `{ label: T }` |
| `(T, {U label})` | `{ $1: T; label: U }` |
| `()` | An empty object; TypeScript `Record<PropertyKey, never>` |
| Nullable structural or scalar node | The corresponding type `\| null` |

The table describes converted leaf types, not Dart type spelling in TypeScript.
Record fields are always required, including fields whose value can be `null`.
Optional nullable List/Map/Dictionary/record parameters can omit the argument, pass `undefined`
to select the default, or pass `null`. Only null structural defaults are currently
supported. A non-null constant List/Map/Dictionary/record default produces `NAPI_DEFAULT` before
compilation or output creation.

| Boundary case | Policy |
| --- | --- |
| Containers | Every occurrence becomes an independent container. Repeating one source List/Map/Dictionary/record in separate branches does not preserve container identity. Output mutation cannot modify the Dart source container. Reference leaves preserve their live wrapper identity and mutable Dart object state. |
| Arrays | Require `Array.isArray`, with `Array.prototype` or null prototype. Typed arrays and custom array prototypes are rejected. Read length once per container, require a numeric uint32 length, then use that snapshot for budget, key bounds and traversal. Invalid lengths fail at `.length`; this also applies to custom Dart output Lists. |
| Record objects | Require an ordinary object with `Object.prototype` or null prototype. Arrays and custom prototypes are rejected. Output records are ordinary mutable objects. |
| Fields and indices | Require own data properties. Sparse indices, missing record fields and accessors are rejected. Accessor getters/setters are never invoked by conversion. Non-enumerable own data properties are accepted. |
| Extra properties | Reject unknown record keys and array properties other than `length` and canonical indices. Symbol keys are also rejected. |
| Cycles | Reject a container already active in the current conversion path. A repeated container after its earlier branch completes is cloned again. |
| Depth | At most 64 structural containers along a path, counting the root as the first. A 65th container fails with `RangeError` at that container's path. |
| Work | Each parameter and result gets its own limit of 10,000 visited values, including containers, scalar leaves and nulls. Before traversing a List or Map, reject its container path if the minimum child work exceeds the remaining budget; each Map entry contributes a key and a value. Other exhaustion errors identify the next value. |
| Failure | Invalid inputs fail before the Dart business function runs. Validation throws `TypeError` or `RangeError` with paths such as `echo.value[2].values[1]`; result paths start with `echo result`. Dart exceptions from business code or custom output List getters or Map iteration become JavaScript `Error`. Failed conversions retain no state between calls. |

Maps use genuine JavaScript Map internal slots, including cross-realm Maps and
subclasses. Map Proxies are rejected. Captured Map intrinsics ignore instance
`size`, `entries` and iterator overrides. Entries are snapshotted into a bounded
flat sequence before converting children, so child conversion cannot extend an
active iterator by reentering and mutating the parent. Dart output uses its actual
`entries` iteration order and checks that its captured uint32 length agrees with
that sequence. Each key and value is recursively converted with paths such as
`echo.value[1].key` and `echo.value[1].value`.

Input Maps use ordinary Dart equality and hashing. Structurally equal record
keys or reference keys with custom `==` may collide even when their original JS
objects differ. Output uses JavaScript Map SameValueZero equality. Either
conversion rejects a duplicate converted key with `TypeError`; it never silently
overwrites an entry. Single `NaN` entries round-trip with their values, although
Dart's ordinary `containsKey(double.nan)` is false. Multiple Dart NaN entries
collide on output. Signed zero keys compare equal; JavaScript Map normalizes
negative zero to positive zero. A source Map's custom comparator is not copied,
and thrown Dart `hashCode` or `==` errors become JavaScript `Error`.
`Map<String, V>` remains a Map, including special keys such as `__proto__`;
use the explicit `Dictionary<V>` API for string-keyed object dictionaries:

```dart
import 'package:napi/napi.dart';

@NAPI()
Dictionary<int> counts(Dictionary<int> value) => value;

final ordinaryMap = <String, int>{'one': 1};
final dictionary = Dictionary(ordinaryMap);
```

`Dictionary<V>` is an extension type implementing `Map<String, V>`; its
constructor adds no runtime wrapper and ordinary Dart Map operations remain
available. The explicit type stays distinct from Map through aliases and
prefixed/re-exported imports. Generated binding code imports the public napi
API directly; business code does not need to re-export it.

Dictionary inputs require a plain or null-prototype object, like record inputs.
All own string keys are accepted, including non-enumerable data properties.
Symbols and accessor properties are rejected without invoking accessors.
Conversion snapshots own keys, then reads one descriptor and converts its value
at a time. Reentrant changes cannot add new keys to that snapshot; removing a
later key causes an own-data error at that key. Output objects have a null
prototype and all keys become enumerable, writable, configurable own data
properties. `__proto__`, `constructor`, empty names, NUL and surrogate code units
are retained safely. JavaScript OwnPropertyKeys order applies, including sorting
array-index names before other strings; this may differ from Dart insertion
order.

Dictionary paths use JSON-quoted brackets, such as `counts.value["name"]`.
Keys are field metadata: the root and value subtrees count toward the 10,000-value
budget, matching record field accounting. Output captures a uint32 length and a
bounded raw-entry snapshot, rejecting length mismatches and duplicate original
string keys before child conversion. A custom Dart Map cannot silently overwrite
an output property. Nullable/default-null, references, rollback, depth/cycle and
exception rules apply exactly as for other structural values.

JavaScript proxies can run their own reflection traps during inspection; the
own-data rule prevents invoking property accessors, not arbitrary proxy code.
Reflection enumerates an object's own keys before checking them. Descriptors are
read one child at a time, immediately followed by that child's recursive
conversion. Both backends use JavaScript Array/prototype checks for Proxy inputs
and preserve thrown reflection exceptions. A Proxy that shrinks a List after
length capture can cause an own-data error at the now-missing index. The work limit
bounds converted values and recursive traversal, not the JavaScript engine's
allocation for that initial key enumeration.

Generated structural traversal uses the scalar and selected-reference leaf
converters. Repeated references in independent cloned containers reuse the same
reachable wrapper, also shared with direct reference calls. Forged, Proxy,
wrong-class and foreign-runtime leaves fail at their precise field/index path.
Dropping the wrapper while Dart retains a container permits collection; returning
the object later adopts a new wrapper without executing its constructor again.
The exact-public-type and lifetime rules in [reference classes](classes.md) apply
equally inside containers. Opaque values and shared buffers remain unsupported.

The shared generated-consumer contract covers nested nullable values, cloning,
strict leaves, descriptor failures, cycles, depth/work boundaries, recovery,
TypeScript, output List getter failures, Proxy reflection order/length capture,
UTF-16 error paths and same-module reentry with GC. Map consumers additionally
cover key collisions, NaN and signed zero, overridden intrinsics, cross-realm
branding, record/reference keys, bigint keys/values, failed-output identity
rollback and Dart-held Map reference collection. Dictionary consumers cover
null-prototype special keys, own-data descriptors, key ordering and JSON paths,
mixed Map/Dictionary signatures, class members, alias recognition and GC. Fresh native/Wasm npm
consumers run it with the original native source/build directories removed.
Tested with Dart 3.13.5, Node 24.19.0/26.11.1 and TypeScript 7.0.2. Native execution
is qualified on macOS arm64 and requires an ABI 6 bundle. The compiler/runtime
use private experimental SDK APIs; other native platforms remain unqualified.

Non-null structural defaults, generic reference specialization and opaque/shared
leaves remain separate work. Failed input conversion does not invoke the exported business method, reference
constructor or setter. Explicit [value-class constructors](values.md) execute
during input materialization after raw validation; domain failures may retain
earlier constructor side effects. Failed output conversion does not undo business mutations;
any temporary wrappers created before failure follow normal garbage collection.
An unsuccessful output conversion discards new public-type identity claims for
objects it did not return. It preserves identities established by earlier
successful calls; failure cannot change an already exposed object's class.
