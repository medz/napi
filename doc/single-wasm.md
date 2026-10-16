# Single-Wasm research

The zero-JavaScript, single-executable proposal was superseded on 2026-10-16 by
the [native and Wasm architecture](architecture.md). Native `.node` addons and
necessary generated JavaScript are now in scope. Consumers must retain
`new Counter()` and normal parameter-presence behavior.

Standalone linking remains optional size/runtime research. Isolated probes showed
that a restricted arithmetic program can run in one Dart Wasm file. They did not
establish the complete binding API, SDK runtime coverage, strict scalar conversion
or production packaging. Those probes are not a delivery gate.

Fixed-arity native Wasm functions cannot recover omitted versus explicitly
undefined arguments and cannot serve as JavaScript constructors. Generated JS
bindings can capture these semantics before calling Dart Wasm. The existing
foundation demonstrates that route with handwritten ABI fixtures; generated
functions and classes still require their own conformance tests.

The earlier research and merged contract remain in Git history. Do not use that
superseded contract to weaken requirements or block native/JS implementation.
