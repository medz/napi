# Argument presence and Dart defaults

The current Wasm backend supports required and optional positional parameters,
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
| Optional positional opaque parameter | Dart default | Supplied value | Supplied value |

`false`, `0`, `-0`, `0n` and `''` remain supplied values. Optional positional holes
work independently: `f(undefined, 0)` defaults only the first parameter. Surplus
JavaScript arguments are ignored; TypeScript declarations expose the declared
arity. All supplied scalars are validated before business code runs.
For an explicitly selected opaque parameter, a supplied `undefined` is a payload
rather than a positional hole. Optional named opaque inputs remain unsupported;
see [opaque payloads](opaque.md).

The frontend evaluates defaults in their declaring library. Generated Dart uses
typed scalar literals, preserving private/imported constant expressions, exact
UTF-16 strings, signed integer values, negative zero, NaN and infinities. No source
expression or private constant name is copied into generated calls. Omitted
nullable parameters without an explicit default use Dart's implicit `null`.
Internal int defaults retain Dart precision even when the JS input policy is
safe-number; normal result range checks still apply. An unresolved, unsupported
or type-incompatible scalar default produces `NAPI_DEFAULT` at the parameter
before compilation or output creation. Unsupported value categories continue to
produce `NAPI_TYPE`. Defaults for future conversion engines need explicit support.

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
argument counts and own-property presence before creating carriers. Fresh
installed packages on both targets verify that `f()` fails while
`f(undefined)` preserves the supplied payload.

Declarations use optional positional parameters and a final typed options object.
Ordinary optional properties explicitly allow `undefined`, including under
`exactOptionalPropertyTypes`. Required nullable properties allow `null` and reject
`undefined` unless explicitly selected as opaque. Optional positional opaque
parameters use finite prefix overloads to preserve their logical payload type;
required named opaque properties use that type without adding `undefined`.

Verified with Dart 3.13.5 stable, Node 26.11.1 and TypeScript 7.0.2; CI also tests
Node 24.19.0. Dart Wasm interop remains experimental.
