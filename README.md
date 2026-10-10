# napi

Write Dart functions. Import them directly from WebAssembly in JavaScript and TypeScript.

```js
import { add } from './dist/module.wasm';

add(20, 22); // 42
```

The imported functions are real Wasm exports. No initialization call or JavaScript entrypoint is required.

## Quick start

Use Dart **3.13.5 or newer** and Node **22.19+ in the 22.x line, or 24.5+**:

```sh
dart pub add napi
```

Write `lib/math.dart`:

```dart
import 'dart:typed_data';
import 'package:napi/napi.dart';

@napi
double add(double a, double b) => a + b;

@napi
String greet(String name) => 'Hello, $name';

@napi
int checksum(Uint8List bytes) {
  var sum = 0;
  for (final byte in bytes) {
    sum = (sum + byte) & 0xff;
  }
  return sum;
}
```

Build:

```sh
dart run napi:build lib/math.dart --name @example/math --out dist --version 0.1.0
```

Then import the generated Wasm file from an ES module:

```js
import { add, greet, checksum } from './dist/module.wasm';

console.log(add(20, 22));                     // 42
console.log(greet('Dart'));                  // Hello, Dart
console.log(checksum(new Uint8Array([1, 2]))); // 3
```

Or install the generated directory as an npm package:

```sh
npm install /absolute/path/to/dist
```

```ts
import { add } from '@example/math';
// Also supported: import { add } from '@example/math/module.wasm';

add(20, 22);
```

Both package entries point to `module.wasm`. The generated package has no npm runtime dependencies. Keep `module.imports.mjs` beside the Wasm file: the Wasm module imports these compiler and value-conversion helpers automatically.

Function and exported public record typedef documentation written with Dart
`///` or `/** ... */` comments is included as JSDoc in both generated declaration
files. JavaScript and TypeScript tools can read the same API description through
package or relative Wasm imports. Typedefs retain their own outer alias comment,
without inheriting documentation from an underlying alias.
Markdown text and examples are preserved; Dartdoc references and directives are
copied as text, without expansion. Comment terminators are escaped for TypeScript.

## Complete application examples

The [request-summary application](example/requests/README.md) reads NDJSON on
stdin, groups requests and checks safe totals in Dart, then prints one JSON
array from Node. It includes a dataset, typed consumer and exact expected output.

```sh
dart pub get
dart run napi:build example/requests/summary.dart --name @napi/requests --out example/requests/dist
node example/requests/main.mjs < example/requests/input.ndjson
```

The Node command directly imports `summarize` from `./dist/module.wasm`. The
example uses the existing typed record/batch API and adds no runtime dependency.

The [file-checksum application](example/checksum/README.md) sends a file's name
and bytes in one native Wasm call. Dart returns its byte count and CRC32; Node
reads the file or stdin and prints JSON.

```sh
dart run napi:build example/checksum/checksum.dart --name @napi/checksum --out example/checksum/dist
node example/checksum/main.mjs example/checksum/sample.txt
```

The example reuses byte records and makes no speedup claim over Node's built-ins.

## Upgrading to 0.13.0

Use `napi: ^0.13.0` in your Dart dependencies and rebuild generated packages
with the existing build command; the `^0.12.0` range excludes this release.
SDK and tested runtime requirements are unchanged; the generated npm package's
version is still set by `--version`.

Flat data objects can now be indexed by key in one native Wasm call:

```dart
typedef User = ({int id, String name});

@napi
Map<String, User> normalizeById(Map<String, User> users) => {
  for (final entry in users.entries)
    entry.key: (id: entry.value.id, name: entry.value.name.trim()),
};
```

```ts
import { normalizeById } from './dist/module.wasm';
import type { User } from './dist/module.wasm';

const users: Record<string, User> = normalizeById({
  ada: { id: 7, name: ' Ada ' },
});
console.log(users.ada.name); // Ada
```

The request-summary application also supports operation lookup through
`summarizeByOperation`. Dictionaries preserve nullable values, byte fields,
call-time snapshots and independent output ownership. Record snapshots and the
checksum example include [measured conversion improvements](doc/performance.md);
these measurements do not promise application speedups. Existing exports and
error categories retain their contracts. See the
[milestone contract](doc/requirements.md#0130-contract) and
[tested platforms](doc/platforms.md).

## Async functions

Return a Dart `Future<T>` to export a JavaScript `Promise<T>`. Both `async` functions and ordinary functions returning a Future are supported:

```dart
@napi
Future<int> addLater(int a, int b) async {
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return a + b;
}
```

```ts
import { addLater } from './dist/module.wasm';

const result: number = await addLater(20, 22); // 42
// Generated declaration: addLater(a: number, b: number): Promise<number>
```

Every call to a Future export returns a genuine Promise. Invalid arguments, synchronous throws, asynchronous failures, and invalid results reject it. `Future<void>` resolves to `undefined`; `Future<T?>` can resolve to `null`. Errors retain the categories below; Dart failures also expose a `dartStack` string. Original JavaScript exception objects and non-null primitive reasons retain their identity. The Dart SDK wraps JavaScript `throw null`, `throw undefined`, and Promise rejection with either value as Dart exceptions; napi reports these as readable JavaScript `Error` objects. Error or stack formatters that throw use a fallback message so rejection can still finish. Failures while reading a JavaScript error's stack cannot replace that error.

Byte inputs are copied during the call, before its first `await`; byte results are copied when the Future completes. Mutating or detaching the caller's input after the call cannot change the Dart snapshot. Futures use the Dart SDK's microtasks and timers; they do not imply execution on another thread or support for `dart:io` or isolates.

## Lists and maps

Export flat collections of `bool`, `int`, `double`, or `String`:

```dart
@napi
List<int> doubleAll(List<int> values) => [for (final value in values) value * 2];

@napi
Map<String, String> labels(Map<String, String> values) => {...values};
```

```ts
import { doubleAll, labels } from './dist/module.wasm';

const input = [1, 2] as const;
const numbers: number[] = doubleAll(input); // [2, 4]
numbers.push(6);
const names: Record<string, string> = labels({ greeting: 'hello' });
```

List parameters accept mutable arrays, `readonly` arrays, `Object.freeze` arrays
and `as const` tuples. `List<int>` takes `readonly number[]` and returns
`number[]`; Dart receives its own mutable List snapshot. Results remain mutable,
including Future completion values such as `Promise<number[]>`.

Containers and elements can be nullable: a `List<int?>?` parameter takes
`readonly (number | null)[] | null`, while its result remains
`Array<number | null> | null`. `Map<String,String?>?` becomes
`Record<string,string | null> | null` in either direction.

Inputs are fully validated and copied before business code runs, including
before returning a Promise. Outputs are new containers at return or Future
completion. Empty containers are independent too. Values use the scalar rules
below; `undefined` is rejected, including in nullable elements. Failures identify
the parameter or result, with the index or key once available.

Lists accept dense Arrays, including cross-realm Arrays. Every index must be an
own data property: holes, inherited indices, and index accessors are rejected
without invoking getters. Extra named and symbol properties are ignored.
Typed arrays continue to use `Uint8List`; they are not accepted as Lists.

Maps accept ordinary objects, including cross-realm objects, and null-prototype
objects. Only own enumerable string data properties are read; accessors are
rejected without invoking getters. Inherited, non-enumerable, and symbol
properties are ignored. Class instances, custom prototypes, Arrays, Date, and
JavaScript Map/Set are rejected. Outputs have a null prototype and retain keys
such as `__proto__`, `constructor`, and `then`; use `Object.hasOwn` rather than
calling methods on the returned object. Key order is not an API guarantee.
Proxy reflection traps still execute as ordinary JavaScript operations; thrown
exceptions follow the existing error policy.

Nested collections, byte-array elements, non-String or nullable Map keys,
raw List/Map types, and collection aliases are rejected before compilation.

## Data objects

Use a named record for fields with different value types. A public non-generic
typedef also becomes an exported TypeScript type:

```dart
typedef User = ({String name, int age, bool? active});

@napi
User normalize(User user) => (
  name: user.name.trim(), age: user.age, active: user.active,
);

@napi
Future<User?> normalizeLater(User? user) async =>
    user == null ? null : normalize(user);
```

```ts
import { normalize, normalizeLater } from './dist/module.wasm';
import type { User } from './dist/module.wasm';

const user: User = normalize({ name: ' Dart ', age: 20, active: null });
const later: User | null = await normalizeLater(user);
```

See [example/users.dart](example/users.dart) for the complete Dart source.
Inline record annotations produce inline object types; imported public aliases,
non-generic alias chains, and nullable record typedef definitions retain their
outer type names. Unused aliases are not exported. These are type-only exports,
with no JavaScript constructor or runtime schema.

Fields must resolve to SDK `bool`, `int`, `double`, `String`, or `Uint8List`,
independently nullable. Non-generic leaf typedefs and chains are accepted:

```dart
typedef UserId = int;
typedef Bytes = Uint8List;
typedef Packet = ({UserId id, Bytes data});
```

The declaration is `export type Packet = { "data": Uint8Array; "id": number }`.
Leaf aliases expand to their underlying types and do not create separate TS
exports or runtime tags. Their existing validation and ownership rules apply.
All declared fields are required: `active: null` is valid, but missing `active`
or `active: undefined` is rejected. Inputs must be ordinary or null-prototype
objects, including cross-realm objects. Declared fields must be own data
properties; non-enumerable data fields are accepted, inherited fields and
accessors are rejected without calling getters. Unknown properties are ignored
without enumerating or reading them. TypeScript is structural and cannot express
all these descriptor/prototype checks.

Declared descriptors are snapshotted and all inputs validated before business
code runs or a Promise returns. Outputs are fresh null-prototype objects with
exactly the declared mutable data fields. Mutating input or output cannot change
another snapshot. Proxy reflection traps still execute; the snapshot is not an
atomic transaction across arbitrary traps. Conversion errors include the field
path, for example `parameter user["age"]`.

Positional, mixed, empty and nested records, generic aliases, collection
fields and class wrappers are unsupported. Collection,
Future, void, function and class aliases remain unsupported. Record aliases named
`readonly`, `keyof`, `infer` or `unique` are rejected before compilation because
TypeScript parses these names as type operators. Ordinary functions and
parameters with these names remain supported; `ReadonlyArray` is a valid record
alias. Type aliases with conflicting
public names or names that shadow generated TypeScript built-ins fail before
compilation. Dart itself prohibits private and Object-member record field names;
use Maps for arbitrary keys such as `__proto__`.

Byte fields become `Uint8Array` and accept Node `Buffer`, offset views and
cross-realm byte arrays, with the same byte rules as top-level `Uint8List`:

```dart
import 'dart:typed_data';
import 'package:napi/napi.dart';

typedef Packet = ({String name, Uint8List payload});

@napi
Packet normalizePacket(Packet value) {
  for (var index = 0; index < value.payload.length; index++) {
    value.payload[index] ^= 0xff;
  }
  return (name: value.name.trim(), payload: value.payload);
}
```

```ts
import { normalizePacket } from './dist/module.wasm';
import type { Packet } from './dist/module.wasm';

const payload = new Uint8Array([0, 128, 255]);
const packet: Packet = normalizePacket({ name: ' sample ', payload });
// packet: { name: 'sample', payload: Uint8Array([255, 127, 0]) }
// payload remains [0, 128, 255].
```

Every non-null byte field is copied before business code runs or a Promise
returns. Each result field receives independent storage, including when Dart
returns the same bytes in multiple fields or rows. Nullable byte fields remain
required; pass `null`, never `undefined`. Detached and out-of-bounds resizable
views fail with a `TypeError` containing the field path. These copies do not
make Proxy traps or concurrent shared-buffer writes an atomic transaction.
`List<Uint8List>` and Map byte values remain unsupported.

## Batches of data objects

Use `List<User>` for ordered batches of flat named records:

```dart
@napi
List<User> normalizeUsers(List<User> users) => [
  for (final user in users) normalize(user),
];

@napi
Future<List<User?>?> normalizeUsersLater(List<User?>? users) async {
  if (users == null) return null;
  await Future<void>.delayed(const Duration(milliseconds: 1));
  return [for (final user in users) user == null ? null : normalize(user)];
}
```

```ts
import { normalizeUsers, normalizeUsersLater } from './dist/module.wasm';
import type { User } from './dist/module.wasm';

const input = [{name: ' Dart ', age: 20, active: null}] as const;
const users: User[] = normalizeUsers(input);
const later: Array<User | null> | null = await normalizeUsersLater([...users, null]);
```

All Array indices and declared record fields are validated and snapshotted
before business code or Promise return. Nullable containers, elements and fields
are independent; `undefined`, holes, inherited indices and index accessors fail.
Inputs follow the List and data-object rules above. Each output is a new Array,
with a fresh null-prototype object at every non-null position, even when the same
input object appears twice. Changing array membership or record fields after a
call cannot change the Dart snapshot. Proxy reflection remains observable and
is not an atomic transaction across the entire batch.

Readonly batch arrays and readonly record fields are accepted, including frozen
rows and arrays. Generated List parameters use `readonly User[]`; the public
`User` alias and returned `User[]` remain mutable. This describes the caller's
input without changing the Dart snapshot or its normal validation/copy costs.

Failures include both index and field once, for example
`parameter users[3]["age"]`. Inline records and public non-generic record
typedefs work; aliases used only inside Lists still become exported types.
Only one List layer is supported. Nested Lists, collection aliases and
collection/record fields remain unsupported. Batch calls still pay
per-record validation, conversion and allocation costs; measure the workload
before choosing a batch size.

## Dictionaries of data objects

Use `Map<String, User>` to access flat named records by key:

```dart
@napi
Map<String, User> normalizeById(Map<String, User> users) => {
  for (final entry in users.entries) entry.key: normalize(entry.value),
};

@napi
Future<Map<String, User?>?> usersLater(Map<String, User?>? users) async => users;
```

```ts
import { normalizeById, usersLater } from './dist/module.wasm';
import type { User } from './dist/module.wasm';

const users: Record<string, User> = normalizeById({
  alice: { name: ' Alice ', age: 20, active: null },
});
console.log(users.alice.name);
const later: Record<string, User | null> | null = await usersLater({ ...users, missing: null });
```

The outer object follows the Map rules above; each value follows the data-object
rules, including `Uint8List` fields. Only own enumerable string data properties
are read from the Map. Container, value and field nullability are independent;
use `null` where declared, never `undefined`. Inline records and public record
aliases work, including aliases used only inside Maps.

All inputs are validated and copied before business code or Promise return.
The outer output and every non-null record are fresh null-prototype objects,
with independent byte storage even when two keys reference the same input.
Errors include the key and field once, such as
`parameter users["alice"]["age"]`. Empty and special keys such as `__proto__`
are preserved. Missing keys return `undefined` in JavaScript; key order is not
guaranteed. Nested collections and collection/record fields remain unsupported.
Dictionary calls retain the normal per-record validation and copy costs.

The request-summary example also exports `summarizeByOperation`, so consumers
can query `summarizeByOperation(observations)['GET /articles']` directly.

## TypeScript

Package imports resolve `index.d.ts` through `exports.types` with either `NodeNext` or `Bundler` module resolution.

For a relative import such as `./dist/module.wasm`, napi also generates `module.d.wasm.ts`. Enable TypeScript's [`allowArbitraryExtensions`](https://www.typescriptlang.org/tsconfig/allowArbitraryExtensions.html):

```json
{
  "compilerOptions": {
    "strict": true,
    "module": "NodeNext",
    "moduleResolution": "NodeNext",
    "allowArbitraryExtensions": true
  }
}
```

The declarations contain the actual exported signatures; no wildcard `.wasm` declaration is needed.

Applications using Node `Buffer` also need Node's type declarations
(`@types/node` and `"types": ["node"]` in `compilerOptions`). The generated
package itself uses `Uint8Array` types and adds no Node type dependency.

## Supported exports

Annotate public top-level functions in the entry library. Use explicit return types and required positional parameters. Extra arguments are ignored, as with ordinary native Wasm functions; missing arguments arrive as `undefined` and fail type checks.

Wildcard (`_`) parameters keep their required positions and type checks; their
declaration bindings use unique `argN` names.

| Dart | JavaScript / TypeScript | Boundary behavior |
| --- | --- | --- |
| `void` | `void` | Return type only; returns `undefined` |
| `bool` | `boolean` | No coercion |
| `int` | `number` | Input and output must be safe integers |
| `double` | `number` | Preserves NaN, Infinity, and negative zero |
| `String` | `string` | Preserves UTF-16 code units |
| `Uint8List` | `Uint8Array` | Copies in and out; Node `Buffer` and cross-realm arrays accepted |
| `List<T>` | `readonly T[]` → `T[]` | Scalars or flat named records; independent input/output Arrays and record objects |
| `Map<String,T>` | `Record<string,T>` | Scalars or flat named records; independent null-prototype objects and byte storage |
| Named record / record typedef | Object shape / exported type | Required flat scalar/byte fields; independent null-prototype output and byte storage |
| `T?` | `T \| null` | Accepts `null`; rejects `undefined` |
| `Future<T>` | `Promise<T>` | Return type only; completion uses the same value rules |

Invalid arguments throw `TypeError`; unsafe integers throw `RangeError`. Dart `ArgumentError` and `TypeError` become JavaScript `TypeError`, Dart `RangeError` becomes JavaScript `RangeError`, and other Dart exceptions become JavaScript `Error` with a readable message.

Non-generic typedefs resolving to SDK `bool`, `int`, `double`, `String` or
`Uint8List` work wherever that leaf type is supported: direct values, Future
completions, scalar List/Map values, non-null String Map keys and record fields.
Effective nullability is preserved, including nullable typedef definitions.
Generic alias chains and aliases for other types are rejected; `List<Bytes>`
remains unsupported when `Bytes` resolves to `Uint8List`. Imported, private and
same-named leaf aliases are expanded without introducing TS bindings; public
record aliases retain their existing naming and conflict checks.

The export name `then` is reserved because dynamic ESM imports treat it as a promise callback; a scalar record field named `then` is allowed. Dart compiler helper names such as `$invokeMain` and `$wasmI16ArrayGet` are also reserved; other `$` names are allowed. Classes, generics, optional/named parameters, generators, streams, and callbacks are not supported. Future parameters, nullable Futures, `FutureOr`, nested Futures, and `async void` exports are also rejected. Ordinary Dart helpers and Wasm-compatible dependencies can be used inside exported functions.

Conditional imports and exports are analyzed using the build SDK's Wasm library
conditions, so signatures and compilation select the same branch. Use
[`dart.library.js_interop`](https://dart.dev/interop/js-interop/package-web#conditional-imports)
for modern Web implementations; the selected signatures must still use the
supported types above.

## Status and platforms

**napi is experimental and targets Node's native Wasm ESM integration.** [Node documents instance-phase Wasm imports](https://nodejs.org/api/esm.html#wasm-instance-phase-imports) as experimental. Synchronous CommonJS `require` is not supported.

The backend uses Dart's experimental Wasm interop and compiler-generated JavaScript helpers. It rewrites the Wasm import section so Node resolves the helpers, string constants, and built-in string operations through ESM; business logic remains Dart Wasm. It does not implement the Node-API C ABI or produce `.node` addons.

Tested compiler: **Dart 3.13.5**. The consumer matrix covers **Node 22.19.0, 24.5.0, 24.21.0 and 26.11.1**, including native imports, strict value and ownership checks, Future settlement and TypeScript 7.0.2 declarations. Other SDK versions allowed by the package constraint may change the experimental helper layout; unsupported layouts fail the build with a diagnostic. The generated Node engine requirement is `^22.19.0 || >=24.5.0`.

An **esbuild 0.28.2 Node application bundle** is tested with the generated Wasm package kept external. Node still loads the original Wasm and its companion host module. Native browser instance imports and bundler transformations of Wasm are unsupported; Chrome 155.0.8059.27 rejected the direct import even with HTTP 200 and the correct Wasm MIME type. A browser's support for WasmGC or source-phase imports alone does not establish support for `import { add } from './module.wasm'`. See [tested platforms and the bundler example](doc/platforms.md).

A separate manual **Webpack 5.111.1 / Node 26.11.1** check also passed with native
Wasm imports kept external in an ESM application bundle. Its built-in
`asyncWebAssembly` transformation failed while parsing Dart GC types. See the
[recorded result and external-Wasm configuration](doc/platforms.md#webpack-with-external-wasm);
this check does not expand the automated matrix or establish browser support.

The build checks signatures before compiling, supports Dart workspaces, and refuses to overwrite unrelated output directories. Rebuilds stage a complete replacement on the destination filesystem and restore the old package if installation fails. Run `dart pub get` in the source package or workspace first. Use `dart run napi:build --help` for options.

## Development

```sh
dart pub get
dart format bin lib test example benchmark tool
dart analyze --fatal-infos
dart test
dart pub publish --dry-run
```

Integration tests build a real package and verify native functions through package, subpath, and relative Wasm imports. Set `NAPI_TSC` to TypeScript's `bin/tsc` to include the TypeScript consumer checks; CI supplies it. `test/js/browser.html` probes native browser loading without a fallback loader.

CI compiles, packs and installs the runtime fixtures once with `dart run tool/runtime_fixtures.dart`, then sets `NAPI_RUNTIME_FIXTURES` to that output for the full test suite and reuses the same artifacts on other Node versions. The tool requires a new or empty output directory. Rebuild fixtures after changing the generator or fixture source; this environment variable is for development tests, not consumer initialization.

Develop through small issues and independently reviewed PRs. Accumulate related
changes into a complete user-facing milestone, then update the version and
publish through a release-preparation PR. Non-urgent fixes and documentation,
CI, tests, benchmarks and examples normally join that milestone.

See the [requirements](doc/requirements.md), [roadmap](doc/roadmap.md), and [performance measurements](doc/performance.md).

MIT licensed. Generated host helpers include the Dart SDK's BSD license notice.
