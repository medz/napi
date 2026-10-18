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

The frontend evaluates defaults in their declaring library. Generated Dart uses
typed scalar literals and built-in const graphs, preserving private/imported
constant expressions, exact UTF-16 strings, signed integer values, negative zero,
NaN and infinities. No source
expression or private constant name is copied into generated calls. Omitted
nullable parameters without an explicit default use Dart's implicit `null`.
Internal int defaults retain Dart precision even when the JS input policy is
safe-number; normal result range checks still apply. An unresolved, unsupported
or type-incompatible scalar default produces `NAPI_DEFAULT` at the parameter
before compilation or output creation. Non-null `List`, `Map`, `Dictionary` and
record defaults are supported when both the declared type and the complete
constant graph contain only structural containers and scalar/null leaves.
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
Defaults containing reference, resource, opaque or value-class leaves remain
unsupported, including empty constants whose declared type contains such a
leaf. Custom constant objects are not reconstructed. Defaults exceeding the
structural work/depth or generated-text limit produce `NAPI_DEFAULT`.

Each optional value uses one branch in generated Dart; named arguments are passed
with their Dart labels. Code size grows linearly with parameter count, without
dynamic invocation or combinations of named-argument branches.

Presence-sensitive functions are immutable externref globals containing JS arrow
functions. They capture actual argc and own-property presence before calling a
private Dart core export. Required positional scalar/structural functions remain native Wasm
function exports, even in the same public module. Consumers import both forms
directly from `.wasm`; neither function form is constructible. This implementation
requires no consumer initialization. Generated opaque functions use the presence
path even when all parameters are required. Native callbacks capture Node-API
argument counts and own-property presence before creating carriers. On both
targets, `f()` fails for a required opaque input while `f(undefined)` preserves
the supplied payload.

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

Compiler and runtime requirements are listed in [the compatibility guide](../README.md#verify).
Dart Wasm interop remains experimental.
