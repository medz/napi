# Direct-Wasm export-kind fixture

This handwritten fixture tests Node's Wasm ESM handling of immutable externref
globals. It complements the generated bindings in the
[class tests](../../../doc/classes.md).

```js
import { Counter, requiredOpaque, optionalOpaque, optionalNumber } from './module.wasm';
```

The public Wasm module imports and reexports the original JS class and
functions. Its host wrapper calls `core.wasm`, where Dart constructs and mutates
`Counter`. Dart `main` deliberately throws and is never called.

## Run

From the repository root, with the [test dependencies](../../../doc/testing.md):

```sh
dart run tool/export_kind_fixture.dart
tsc --project test/fixtures/export_kinds/tsconfig.json
```

The helper links the fixture under `.dart_tool`, runs the Node consumer and
prints its artifact directory. `buildExportKindFixture` returns that directory
for other test drivers; `repositoryRoot` can select a different source tree.
The declarations and host wrapper are handwritten.

The fixture covers import identity, construction and receiver brands, required
and optional opaque presence, and ordinary numeric defaults. Its numeric values
are signed 32-bit integers; production bindings use the separate
[scalar conversion rules](../../../doc/scalars.md). The diagnostic core exports
are internal test helpers, not a public handle API.
