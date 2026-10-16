# Lists and records

The Wasm backend converts nested `List<T>` and Dart records in both directions.
Every structural node can be nullable. Leaves use the existing strict scalar
rules for `bool`, `String`, `int`, `double` and `BigInt`; `@NAPI(bigint: true)`
applies recursively to Dart `int` leaves.

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
| `(T,)` | `{ $1: T }` |
| `(T, U)` | `{ $1: T; $2: U }` |
| `({T label})` | `{ label: T }` |
| `(T, {U label})` | `{ $1: T; label: U }` |
| `()` | An empty object; TypeScript `Record<PropertyKey, never>` |
| Nullable structural or scalar node | The corresponding type `\| null` |

The table describes converted leaf types, not Dart type spelling in TypeScript.
Record fields are always required, including fields whose value can be `null`.
Optional nullable List/record parameters can omit the argument, pass `undefined`
to select the default, or pass `null`. Only null structural defaults are currently
supported. A non-null constant List/record default produces `NAPI_DEFAULT` before
compilation or output creation.

| Boundary case | Policy |
| --- | --- |
| Containers | Every occurrence becomes an independent container. Repeating one source List/record in separate branches does not preserve container identity. Output mutation cannot modify the Dart source container. |
| Arrays | Require `Array.isArray`, with `Array.prototype` or null prototype. Typed arrays and custom array prototypes are rejected. |
| Record objects | Require an ordinary object with `Object.prototype` or null prototype. Arrays and custom prototypes are rejected. Output records are ordinary mutable objects. |
| Fields and indices | Require own data properties. Sparse indices, missing record fields and accessors are rejected. Accessor getters/setters are never invoked by conversion. Non-enumerable own data properties are accepted. |
| Extra properties | Reject unknown record keys and array properties other than `length` and canonical indices. Symbol keys are also rejected. |
| Cycles | Reject a container already active in the current conversion path. A repeated container after its earlier branch completes is cloned again. |
| Depth | At most 64 structural containers along a path, counting the root as the first. A 65th container fails with `RangeError` at that container's path. |
| Work | Each parameter and result gets its own limit of 10,000 visited values, including containers, scalar leaves and nulls. Before traversing a List, reject its container path if its length exceeds the remaining budget. Other exhaustion errors identify the next value. |
| Failure | Invalid inputs fail before the Dart business function runs. Validation throws `TypeError` or `RangeError` with paths such as `echo.value[2].values[1]`; result paths start with `echo result`. Dart exceptions from business code or custom output List getters become JavaScript `Error`. Failed conversions retain no state between calls. |

JavaScript proxies can run their own reflection traps during inspection; the
own-data rule prevents invoking property accessors, not arbitrary proxy code.
Reflection enumerates an object's own keys before checking them. The work limit
bounds converted values and recursive traversal, not the JavaScript engine's
allocation for that initial key enumeration.

Generated structural traversal has a leaf-adapter interface. Its contract tests
verify that an identity adapter preserves leaf identity while copying the
containers. Production currently supplies only scalar leaves: this does not
implement opaque values, reference handles, shared buffers, class construction,
or Map/dictionary conversion.

The source-to-Wasm fixtures cover nested nullable values, cloning, strict leaves,
descriptor failures, cycles, depth/work boundaries, recovery, TypeScript and
output List getter failures. Tested with Dart 3.13.5 and Node 24.19.0; the compiler
adapter uses private experimental SDK APIs. Native Node-API `.node` conformance
remains open until its runtime and generator exist; Wasm results do not establish
native parity.
