# Scalar conversion contract

Exported functions, constructors, methods and properties support scalar values,
including [optional and named arguments](arguments.md). Both backends share the
same runtime conversions and TypeScript representations. Wasm supports direct named `.wasm`
imports; native packages use their generated ESM entry. Neither requires manual
consumer initialization.

## Representations

| Dart type | JavaScript and TypeScript | Accepted values |
| --- | --- | --- |
| `bool` | `boolean` | Primitive `true` or `false` |
| `String` | `string` | Primitive strings; exact UTF-16 code units |
| `double` | `number` | Any primitive number, including NaN, infinities and negative zero |
| `int` by default | `number` | Primitive safe integers from −(2⁵³−1) through 2⁵³−1 |
| `int` with `@NAPI(bigint: true)` | `bigint` | Primitive bigint from −2⁶³ through 2⁶³−1 |
| `BigInt` | `bigint` | Primitive arbitrary-precision bigint; no fixed 64-bit limit |

Ordinary synchronous `void` functions and methods return JavaScript `undefined` on both
backends, with a TypeScript `void` result. Arguments keep their usual validation,
presence and defaults, and business exceptions still throw synchronously.
Resource cleanup methods follow the [resource contract](resources.md) instead:
their JavaScript result is `Promise<void>`, including Dart `void` cleanup methods,
and failures reject that Promise.
`void` parameters and `async void` exports are rejected; asynchronous completion
uses `Future<void>`.

A nullable Dart scalar uses the same representation plus `null`. For example,
`String?` becomes `string | null`, and `int?` becomes `number | null` or
`bigint | null` according to the function's policy. Typedefs retain the underlying
Dart type and nullability.

The `bigint` annotation option applies to all Dart `int` parameters and the
`int` result of the annotated function. It never switches representation based
on the value, never accepts both number and bigint for one int parameter, and
does not alter `double`, `bool`, `String` or Dart `BigInt`. An export rename can
be combined with this policy:

```dart
import 'package:napi/napi.dart';

@NAPI(name: 'addWide', bigint: true)
int sum(int left, int right) => left + right;

@NAPI()
BigInt addExact(BigInt left, BigInt right) => left + right;

@NAPI()
String? echoText(String? value) => value;
```

```js
import { addWide, addExact, echoText } from './module.wasm';
addWide(9007199254740992n, 1n); // 9007199254740993n
addExact(1n << 200n, 1n);      // arbitrary-precision Dart arithmetic
echoText(null);               // null
echoText('a\ud800b');         // same UTF-16 code units, including lone surrogate
```

The selected `int` representation changes boundary conversion, not Dart arithmetic
semantics. Bigint-represented Dart `int` still has signed 64-bit
arithmetic; use Dart `BigInt` for arbitrary-precision calculations.

## Validation and preservation

Inputs must already be primitive values of the specified type. There is no
truthiness conversion, numeric parsing, object unboxing or stringification.
Objects, arrays, functions, boxed primitives and symbols are rejected without
calling their coercion hooks. All arguments are validated before the business
function is invoked, including arguments in branches the function would not use.

`null` is accepted only for nullable types. Explicit `undefined` and missing
required arguments always fail, even for nullable parameters. A nullable
parameter is not optional. Optional positional and named parameters default for
omission and `undefined`; explicit `null` still requires a nullable type.

Number-represented `int` rejects fractions, NaN, infinities and unsafe integers.
Both its inputs and results are range-checked; an out-of-range result fails
rather than being rounded silently. Negative zero becomes integer zero.
Bigint-represented `int` rejects out-of-range input before conversion instead of
truncating or wrapping it at the boundary. Dart `BigInt` preserves magnitude and
sign across the boundary, including values well beyond 64 bits.

`double` preserves the JavaScript numeric value, including NaN, positive/negative
infinity and the sign of zero. NaN payload bits are not part of the API contract.
Strings preserve UTF-16 code units in both directions, including embedded NUL,
surrogate pairs and unpaired high or low surrogates; no UTF-8 replacement or
Unicode normalization is performed.

## Errors and declarations

Wrong primitive types, forbidden `null`, `undefined` and omission throw ordinary
JavaScript `TypeError`. Numeric range failures throw `RangeError`. Boundary
messages identify the export and parameter, or identify the result for output
failures. Invalid arguments do not enter business code. A rejected result occurs
after the business function has run, so it does not roll back Dart side effects.

Dart exceptions are surfaced as ordinary JavaScript errors, not raw
`WebAssembly.Exception` values. An exception whose own description throws still
gets a safe fallback description. A failed conversion or call does not poison
the module: subsequent valid calls remain usable.

Generated TypeScript declarations use the exact fixed representation, explicit
`| null` where appropriate, and required parameters without `?` or `undefined`.
Optional parameters and options properties follow the argument contract.
See the [compatibility requirements](../README.md#verify).
