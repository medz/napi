# Lists, Maps, Dictionaries and records

Both Dart Wasm and native Node-API backends convert nested `List<T>`, `Map<K, V>`,
explicit `Dictionary<V>` and Dart records in both directions.
Every structural node can be nullable. Leaves use the existing strict scalar
rules for `bool`, `String`, `int`, `double` and `BigInt`, or the selected
reference-class contract. Open generic declarations also support [opaque](opaque.md)
`T`/`T?` leaves in Lists, Dictionaries, records and Map values, plus selected
references such as `List<Box<T>>`. [JsArray/JsMap handles](collections.md) can be
leaves inside copied containers and value classes, preserving their original JS
source identity. Opaque values and handles cannot be Map keys.
[Value classes](values.md) compose as nested structural
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

| Dart shape | JavaScript / TypeScript output shape |
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
List inputs accept recursively readonly arrays; outputs are mutable arrays.
Record fields are always required, including fields whose value can be `null`.
Optional nullable List/Map/Dictionary/record parameters can omit the argument, pass `undefined`
to select the default, or pass `null`. Non-null constant defaults support
structural containers with scalar, null and selected reference/value objects.
Resource leaves acquire operation leases before callbacks or signal getters can
reenter cleanup, including repeated aliases and Map keys.
Defaults preserve Dart const identity; returning them
still creates ordinary copied JS containers. See [argument defaults](arguments.md)
for supported constants and limits.

Public non-generic record typedefs used by selected bindings are exported as
TypeScript types. Each alias describes the mutable output shape with the default
number policy for Dart `int`. Function signatures keep their direction-specific
inline shapes, including readonly List inputs and `bigint: true` conversions.
Private and instantiated generic record aliases remain inline types.

| Boundary case | Policy |
| --- | --- |
| Containers | Every occurrence becomes an independent container. Repeating one source List/Map/Dictionary/record in separate branches does not preserve container identity. Output mutation cannot modify the Dart source container. Reference leaves preserve their live wrapper identity and mutable Dart object state. Opaque leaves preserve their original JS value and are never traversed or copied. |
| Arrays | Require `Array.isArray`, with `Array.prototype` or null prototype. Typed arrays and custom array prototypes are rejected. Read length once per container, require a numeric uint32 length, then use that snapshot for budget, key bounds and traversal. Invalid lengths fail at `.length`; this also applies to custom Dart output Lists. |
| Record objects | Require an ordinary object with `Object.prototype` or null prototype. Arrays and custom prototypes are rejected. Output records are ordinary mutable objects. |
| Fields and indices | Require own data properties. Sparse indices, missing record fields and accessors are rejected. Accessor getters/setters are never invoked by conversion. Non-enumerable own data properties are accepted. |
| Opaque nullish values | Present `null` and `undefined` remain distinct payloads, each a non-null Dart carrier, including `T?` leaves. A missing structural field/index is still invalid. A genuine Dart null in a nullable leaf returns JS null. |
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

Outputs first snapshot the complete Dart tree, including custom List getters and
Map iteration, with the depth/work/cycle checks above. Host-side integer range,
reference-brand and converted Map-key checks run afterward on that snapshot.
Thus a later Dart getter/iterator failure precedes an earlier invalid host leaf;
no getter is evaluated again during host conversion. Both targets follow this
order. Snapshot storage is proportional to the visited shape and bounded by the
same work limit.

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
The canonical membership and lifetime rules in [reference classes](classes.md) apply
equally inside containers. [SharedBytes](shared-bytes.md) leaves retain their live
shared views inside structural values. Opaque leaves preserve the original JS
value without inspecting it.

Structural defaults containing opaque leaves, opaque
Map keys and JS collection handles as Map keys are not supported.
Open generic resource/value classes are still unsupported. Failed input conversion
does not invoke the exported business method, reference constructor or setter.
Explicit [value-class constructors](values.md) execute
during input materialization after raw validation; domain failures may retain
earlier constructor side effects. Failed output conversion does not undo business mutations;
any temporary wrappers created before failure follow normal garbage collection.
An unsuccessful output conversion discards new public-type identity claims for
objects it did not return. It preserves identities established by earlier
successful calls; failure cannot change an already exposed object's class.
