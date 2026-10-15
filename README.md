# napi

A Dart-to-WebAssembly binding compiler for direct Node ESM imports:

```js
import { add } from './module.wasm';
console.log(add(20, 22));
```

This branch establishes the clean rebuild described in [#115](https://github.com/medz/napi/issues/115).
It is a development foundation, not a new release or the complete binding API.

## Working foundation

- Analyzer-independent declarations, validation, lowering, and Dart/JS/TypeScript emitters
- Required positional Dart `int` functions with JavaScript safe-integer inputs and outputs
- A pinned Dart SDK adapter and linker producing actual Wasm named exports
- Handwritten ABI fixtures proving real Dart constructors and argument-presence semantics
- Direct imports, installed package resolution, artifact inspection, and strict TypeScript tests

The generated JavaScript files are dependencies imported by Wasm. Consumers need
no JavaScript entrypoint, loader setup, registration, or call to application `main`.

Annotation discovery, complete scalar/optional/class bindings, and production npm
package assembly remain separate work in [#114](https://github.com/medz/napi/issues/114).
The `NAPI` annotation is defined, but this foundation does not yet discover it.
The compiler's internal build API takes handwritten semantic IR.

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
dart pub publish --dry-run
```

`tool/verify.dart` builds fresh artifacts and executes the real Node ESM consumers,
including an npm-packed fixture installed offline into a separate consumer.
It checks TypeScript in NodeNext and Bundler modes. `NAPI_TSC` can select an
already installed TypeScript executable.

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
