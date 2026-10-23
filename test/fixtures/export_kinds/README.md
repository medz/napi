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

From the repository root, with the [test dependencies](../../../CONTRIBUTING.md):

```sh
dart test -P wasm-consumers --name 'Wasm export kinds'
```

The declarations and host wrapper are handwritten.

The fixture covers import identity, construction and receiver brands, required
and optional opaque presence, and ordinary numeric defaults. Its numeric values
are signed 32-bit integers; production bindings use the separate
[scalar conversion rules](../../../doc/scalars.md). The diagnostic core exports
are internal test helpers, not a public handle API.
