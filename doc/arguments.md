# Argument presence and Dart defaults

Both backends support required and optional positional parameters,
or required positional parameters followed by named parameters. Named parameters
become one final JavaScript options object:

```dart
const _fallback = 6 * 7;
@NAPI()
int choose(int base, {required int? value, int extra = _fallback}) =>
    base + (value ?? 0) + extra;
```

```js
import {choose} from './module.wasm';
choose(1, {value: null});                   // 43
choose(1, {value: 0, extra: undefined});     // 43
choose(1, {value: 0, extra: 0});             // 1
choose(1, {});                             // TypeError: value is required
choose(1, {value: undefined});              // TypeError: value is required
```

The options argument is optional only when every named parameter is optional.
Omission or `undefined` supplies no named properties. `null`, arrays, functions
and objects with a prototype other than `Object.prototype` or `null` are rejected.
Only own data properties supply arguments, including nonenumerable properties.
Inherited properties are ignored. Unknown own keys, symbols and accessors are
rejected; getters are never invoked. Property descriptors are captured once
before conversion. Proxy traps can still execute while inspecting an object.

| Parameter policy | Omitted | Supplied `undefined` | Supplied `null` |
| --- | --- | --- | --- |
| Required scalar, including nullable | TypeError | TypeError | Accepted only if nullable |
| Optional scalar | Dart default | Dart default | Accepted only if nullable |
| Required opaque parameter | TypeError | Supplied value | Supplied value |
| Optional opaque parameter, positional or named | Dart default | Supplied value | Supplied value |

`false`, `0`, `-0`, `0n` and `''` remain supplied values. Optional positional holes
work independently: `f(undefined, 0)` defaults only the first parameter. Surplus
JavaScript arguments are ignored; TypeScript declarations expose the declared
arity. All supplied scalars are validated before business code runs.
For a generic payload parameter, a supplied `undefined` is a payload
rather than a positional hole or absent named property. Only omission selects
its Dart default; see [opaque payloads](opaque.md).

Defaults are evaluated in their declaring library, preserving private/imported
constant expressions, exact UTF-16 strings, signed integer values, negative zero,
NaN and infinities. Omitted nullable parameters without an explicit default use
Dart's implicit `null`.
Internal int defaults retain Dart precision even when the JS input policy is
safe-number; normal result range checks still apply. An unresolved, unsupported
or type-incompatible scalar default produces `NAPI_DEFAULT` at the parameter
before compilation or output creation. Non-null `List`, `Map`, `Dictionary` and
record defaults may contain scalars, null and selected reference/value objects.
Object defaults use their evaluated public const constructor and arguments;
private constant variables and public factories redirecting to private classes
retain their original Dart identity. Constructor arguments may include other
publicly constructible constants without exporting those helper types to JS.
Private constructors and auxiliary constant values also work when the default
names a public const variable, directly or through constant aliases. A public
static const on a public class can supply the same kind of object. Its private
implementation and helper values stay in Dart.
Actual constant types are preserved, including `const <Never>[]`, nested
Dictionary representations, map insertion order and canonical const identity.
Defaults stay in Dart; returning one still uses the normal output conversion.

```dart
const _fallbacks = <String, List<int>>{'small': [1, 2]};
@NAPI()
int first({Map<String, List<int>> values = _fallbacks}) => values['small']!.first;
```

Omission, `undefined` options and `{values: undefined}` select the same Dart
constant. A supplied `null` remains invalid for this non-null parameter.
For example, `Point point = const Point(0, 0)` works for an exported reference or
value class with a public const constructor. This also applies to optional
fields in a value class's configured input constructor. Optional positional holes
still work independently when later arguments are supplied.

Direct resource parameters and built-in List, Map, Dictionary and record
defaults acquire the same operation leases as explicit inputs; see
[resource defaults](resources.md#constant-defaults). Value-class input properties
also support these resource defaults, with leases acquired before later fields or
callbacks run. When a library exports resources, value-object defaults may contain
only scalar fields or built-in containers of scalars. Supply objects with reference
or nested value-class fields explicitly.
Opaque defaults remain unsupported, including empty containers
declared with opaque element types. An object that has neither a reconstructible
public constructor nor a reachable public const binding produces `NAPI_DEFAULT`.
Unsupported constant kinds outside those objects are also diagnosed.
Defaults exceeding the
structural work/depth or generated-text limit produce `NAPI_DEFAULT`.

Both targets preserve the actual argument count and own-property presence before
calling Dart. Consumers use normal function calls without initialization or
explicit presence parameters. Exported functions are not JavaScript constructors.
For a required opaque input, `f()` fails while `f(undefined)` preserves the
supplied payload.

Declarations use optional positional parameters and a final typed options object.
Ordinary optional properties explicitly allow `undefined`, including under
`exactOptionalPropertyTypes`. Required nullable properties allow `null` and reject
`undefined` unless their type is a generic payload. Optional positional opaque
parameters use finite prefix overloads to preserve their logical payload type;
required named opaque properties use that type without adding `undefined`.
Optional named opaque properties use standard `value?: T | null` declarations.
With strict null checking and `exactOptionalPropertyTypes`, a present `undefined`
requires a payload type that includes it. Without that flag, TypeScript permits
it through its ordinary optional-property rules. Runtime presence remains exact
in either mode; no configuration-gating helper or extra presence parameter is
added.

See the [compatibility requirements](../README.md#verify).
