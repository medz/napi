# Development

Keep this package small: one annotation, one build command, one export model.
Business logic must execute in Dart Wasm with real named Wasm exports.
Consumers import functions directly from .wasm or an npm entry pointing to it.
Do not replace that API with manual initialization or a JavaScript entrypoint.
Do not add a native addon backend, build_runner, or a plugin framework.

Run format, analyze, tests (including Node and TypeScript), and pub dry-run.
Document tested compiler/runtime versions; the Dart Wasm interop is experimental.

# Code review

Report correctness defects at every priority, including P2. Check generated
code and fresh-consumer behavior, not only the generator source. Pay attention
to reference and buffer lifetimes, errors, nullable values, integer precision,
UTF-16 strings, typed-array ownership, and output-directory safety.
