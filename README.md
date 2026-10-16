# napi

A Dart-to-WebAssembly binding compiler for direct Node ESM imports:

```js
import { add } from './module.wasm';
console.log(add(20, 22));
```

This branch builds on the clean rebuild described in [#115](https://github.com/medz/napi/issues/115).
It is a development foundation, not a new release or the complete binding API.

The target artifact is now **one `module.wasm` with no distributed JavaScript**.
The current development compiler still generates JS host dependencies and has
not reached that target. [The single-Wasm plan](doc/single-wasm.md) records the
replacement path, verified boundaries, and outstanding requirements in
[#144](https://github.com/medz/napi/issues/144). Existing JS-dependent fixtures
remain regression evidence for the earlier contract, not zero-JS acceptance.

## Working foundation

- Resolved `@NAPI()` discovery with renaming, class/member selection and reexports
- Analyzer-independent declarations, validation, lowering, and Dart/JS/TypeScript emitters
- Required positional scalar functions: `bool`, `String`, `double`, `int`, `BigInt`, and nullable forms
- Safe-number `int` by default, or fixed JavaScript `bigint` with `@NAPI(bigint: true)`
- A pinned Dart SDK adapter and linker producing actual Wasm named exports
- Handwritten ABI fixtures proving real Dart constructors and argument-presence semantics
- Direct imports, installed package resolution, artifact inspection, and strict TypeScript tests

The current generated JavaScript files are dependencies imported by Wasm. The
replacement must eliminate them from the complete artifact graph, preserve direct
imports, and require no loader setup, registration, or call to application `main`.

The annotation frontend records complete declaration metadata; build-time checks
reject unsupported signatures before writing output. Optional-parameter/class
execution and production npm package assembly remain separate work in
[#114](https://github.com/medz/napi/issues/114). See [annotation syntax and scope](doc/annotations.md) and the
[scalar conversion contract](doc/scalars.md).
Annotated sources import `package:napi/napi.dart`; separate Dart VM build scripts
use `buildLibrary` from `package:napi/build.dart`.

## Scalar conversions

```dart
import 'package:napi/napi.dart';

@NAPI()
String? echo(String? value) => value;

@NAPI(bigint: true)
int addWide(int left, int right) => left + right;
```

```js
import { echo, addWide } from './module.wasm';
echo(null);           // null
echo('🙂');           // '🙂'
addWide(1n, 2n);      // 3n
```

Conversions never coerce input values. Nullable parameters accept `null`, but not
`undefined` or omission. `double` preserves NaN, infinities and negative zero;
strings preserve UTF-16 code units, including lone surrogates. Default `int`
checks the JavaScript safe-integer range in both directions. The `bigint` option
maps all Dart `int` inputs/results of that function to JavaScript `bigint` with a
signed 64-bit input range; Dart `BigInt` always uses arbitrary-precision JavaScript
`bigint`. See [the full contract](doc/scalars.md), including error behavior.

## Verify

The current tested toolchain is Dart **3.13.5 stable**, Node **24.19.0**, and
TypeScript **7.0.2**. The SDK adapter deliberately rejects other Dart versions.
Node's Wasm module warning is expected on this version. Bun, browsers, and native
`.node` addons are outside this version's target.

```sh
dart pub get
npm install --prefix .dart_tool/js --no-save --no-package-lock --ignore-scripts typescript@7.0.2
dart format --output=none --set-exit-if-changed lib test tool
dart analyze --fatal-infos
dart test
dart run tool/verify.dart
dart run tool/check_package.dart
```

`tool/verify.dart` builds fresh artifacts and executes the real Node ESM consumers,
including an npm-packed fixture installed offline into a separate consumer.
It checks TypeScript in NodeNext and Bundler modes. `NAPI_TSC` can select an
already installed TypeScript executable. Package validation permits only the
expected warning for the exact analyzer pin; every other warning or error fails.

To inspect just the generated scalar fixture:

```sh
dart run tool/scalar_fixture.dart .dart_tool/scalar-example
node .dart_tool/scalar-example/test.mjs
```

Relative `.wasm` imports use a sibling `module.d.wasm.ts` and TypeScript's
`allowArbitraryExtensions` option. The installed test package's root and
`./module.wasm` subpath both resolve directly to the Wasm file.

See [the foundation design](doc/foundation.md) for the export representation,
initialization, SDK coupling, scope, and rebuild decisions.

## License

MIT. See [LICENSE](LICENSE). Generated Dart runtime helpers originate in the Dart
SDK. Generated artifacts include its license as `DART_LICENSE`; distributors
must retain that notice.
