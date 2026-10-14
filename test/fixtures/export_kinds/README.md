# Direct-Wasm export-kind regression

This handwritten fixture proves a backend capability. It is **not generated
class support** and does not make class declarations accepted by the compiler
frontend. Class generation remains separate work (#123).

The consumer's entry is a real Wasm module:

```js
import { Counter, requiredOpaque, optionalOpaque, optionalNumber } from './module.wasm';
```

`module.wasm` imports and reexports immutable externref globals. Node's native
Wasm ESM loader unwraps them to the original JS class/functions. The host class
retains a real externalized Dart `Counter`; construction, reads, mutations, and
opaque/number function bodies execute in `core.wasm`. The private host is a Wasm
dependency, not a JavaScript package entry or consumer bootstrap. The Dart main
function deliberately throws and is never called.

## Reproduce

Run from the repository with Dart 3.13.5 stable and Node 24.19.0:

```sh
dart run tool/export_kind_fixture.dart
tsc --project test/fixtures/export_kinds/tsconfig.json
```

The Dart helper invokes the pinned SDK adapter and linker, materializes the
private-ABI text fixture under `.dart_tool`, runs the native Node test, and prints
the artifact directory. The exported `buildExportKindFixture` function returns
that directory for other test drivers; an optional `repositoryRoot` selects the
source tree. TypeScript 7.0.2 was tested in strict NodeNext mode with
`allowArbitraryExtensions`, using `module.d.wasm.ts` for the actual Wasm import.
The declarations and host wrapper are handwritten regression artifacts.

## Contracts exercised

- Repeated and concurrent native ESM imports retain the same namespace and
  public class/function identities without creating extra Dart instances.
- `new Counter()` calls a real Dart constructor. Each wrapper retains a distinct
  Dart object. Its getter/method reads and mutates that object repeatedly.
- Only signed 32-bit fixture values are accepted. Mutation checks the result
  range before calling Dart, avoiding silent Wasm i32 truncation. This fixture
  does not define the production integer ABI.
- Private-field brands reject forged, detached, proxy, and foreign-runtime
  receivers. Two separately linked copies retain independent Dart state.
- `requiredOpaque()` rejects without invoking Dart; an explicit `undefined` is
  supplied and round-trips unchanged, as do null, symbol, bigint, object, and
  function values. Reference identity is preserved.
- `optionalOpaque()` omits the Dart argument and selects `dart-default`.
  `optionalOpaque(undefined)` and `optionalOpaque(null)` pass distinct wrapped
  values through Dart and preserve them.
- `optionalNumber()` and `optionalNumber(undefined)` both omit the ordinary Dart
  argument and select its default, 7. Null and other invalid numbers reject.
- As with ordinary JavaScript calls, surplus runtime arguments are ignored. The
  declarations expose only the intended parameter list.
- Private diagnostic exports count business calls, preventing a JavaScript-only
  imitation from satisfying the test.

## Limits

The experimental fixture uses `dart:_wasm` and `dart:_js_interop_wasm`, pinned to
Dart 3.13.5. Node 24.19.0 reports native Wasm instance imports as experimental.
Other runtimes are not established by this test, including Bun's different
native Wasm import behavior. There is no full class/opaque frontend, generator,
disposal/finalization, serialization, worker transfer, asynchronous method, or
general error-normalization claim here. Ownership applies to the public wrapper
receiver; the diagnostic/private core ABI is not a hardened public handle API.
