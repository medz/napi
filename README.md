# napi

A Dart-to-JavaScript binding compiler, being rebuilt around Dart Wasm and generated Node/Bun ESM modules.

This checkout implements the **compiler/runtime foundation** in [#115](https://github.com/medz/napi/issues/115), plus an early loading and installation experiment for [#107](https://github.com/medz/napi/issues/107). It is not the complete binding redesign or a new release. The old implementation is replaced, without a compatibility layer. Published 0.14.0 behavior is recorded in [the historical documentation](doc/history/0.14.0/README.md) and [changelog](CHANGELOG.md).

## Executable foundation

The fixture runner exercises this real pipeline:

```text
explicitly selected Dart functions
  → analyzer frontend → immutable binding IR → validation
  → call/conversion/lifetime plans → specialized Dart / JS / TypeScript
  → dart compile wasm → unchanged SDK loader → ready-on-import ESM
```

The installed fixture is consumed without handwritten initialization:

```js
import { add } from '@napi/foundation-fixture';

add(20, 22); // 42, executed in Dart Wasm
```

Supported by the fixture: synchronous top-level functions with explicitly typed, required positional `int`, `double`, `bool` and `String` parameters and those return types or `void`. Integers are checked JavaScript safe numbers in both directions. Doubles preserve NaN, infinities and negative zero; strings preserve UTF-16 code units. Errors cross the bridge as JavaScript errors with Dart diagnostic detail.

`@NAPI()` and `@NAPI(name: 'publicName')` are the single annotation API. Annotation discovery, renaming through the frontend and external bindings are **not implemented yet**; the fixture selects Dart declaration names explicitly. Unsupported declarations fail with source-located diagnostics instead of receiving placeholder behavior.

## Run the checks

The exact tested development matrix is Dart **3.13.5**, Node **24.19.0**, Bun **1.4.3**, TypeScript **7.0.2** on Linux x64. This is fixture evidence, not a claim that every newer version or platform is supported.

```sh
dart pub get
npm install --prefix .dart_tool/js --no-save --no-package-lock --ignore-scripts --no-audit --no-fund typescript@7.0.2
dart format --output=none --set-exit-if-changed lib test tool
dart analyze --fatal-infos
dart test
NAPI_TSC="$PWD/.dart_tool/js/node_modules/.bin/tsc" dart run tool/runtime_fixtures.dart
bash tool/ci_scope_test.sh
dart pub publish --dry-run
```

Install Node and Bun through their official distributions and put them on PATH. `NAPI_NODE`, `NAPI_BUN`, `NAPI_NPM` and `NAPI_TSC` can select executable paths. The fixture runner compiles Wasm once, packs a local fixture, installs it in a fresh consumer, runs real Node and Bun assertions, and checks strict TypeScript consumers in NodeNext and Bundler modes. Failure/cleanup tests using fake loaders are explicitly separate from real Wasm tests.

To compile the fixture without consumer checks:

```sh
dart run tool/runtime_fixtures.dart --compile-only
```

Outputs are new directories under `.dart_tool/napi-fixtures/`; source files and existing builds are never overwritten. The fixed private fixture package is test infrastructure. There is no general-purpose `napi:build` command or production npm metadata handling in this foundation.

## Architecture and next work

- [Architecture, ownership boundaries and adapter contracts](doc/architecture.md)
- [Implemented requirements and explicit exclusions](doc/requirements.md)
- [Loading behavior and compatibility evidence](doc/platforms.md)
- [Implementation roadmap](doc/roadmap.md)

Collections, nullable/optional/named parameters, opaque values, generic binding semantics, classes, resources, buffers, callbacks, Futures and streams remain follow-up work. Their runtime interfaces describe obligations; they do not claim working engines. Browser packages and native `.node` output are outside this redesign.
