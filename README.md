# napi

A Dart-to-WebAssembly binding compiler for direct Node ESM imports:

```js
import { add } from './module.wasm';
console.log(add(20, 22));
```

This branch builds on the clean rebuild described in [#115](https://github.com/medz/napi/issues/115).
It is a development foundation, not a new release or the complete binding API.

## Working foundation

- Resolved `@NAPI()` discovery with renaming, class/member selection and reexports
- Analyzer-independent declarations, validation, lowering, and Dart/JS/TypeScript emitters
- Required positional Dart `int` functions with JavaScript safe-integer inputs and outputs
- A pinned Dart SDK adapter and linker producing actual Wasm named exports
- Handwritten ABI fixtures proving real Dart constructors and argument-presence semantics
- Direct imports, installed package resolution, artifact inspection, and strict TypeScript tests

The generated JavaScript files are dependencies imported by Wasm. Consumers need
no JavaScript entrypoint, loader setup, registration, or call to application `main`.

The annotation frontend records complete declaration metadata; build-time checks
reject unsupported signatures before writing output. Complete scalar/optional/class
execution and production npm package assembly remain separate work in
[#114](https://github.com/medz/napi/issues/114). See [annotation syntax and scope](doc/annotations.md).
Annotated sources import `package:napi/napi.dart`; separate Dart VM build scripts
use `buildLibrary` from `package:napi/build.dart`.

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
