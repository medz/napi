# Running tests

Use Dart 3.13.5 and Node.js 24.19.0. CI also checks generated consumers with
Node.js 26.11.1. Install package and TypeScript dependencies from the repository
root:

```sh
dart pub get
npm install --prefix .dart_tool/js --no-save --no-package-lock \
  --ignore-scripts --no-audit --no-fund typescript@7.0.2
```

To check both Node versions locally, set `NAPI_NODE_EXECUTABLES` to a JSON array
containing the absolute paths to both installed executables. Otherwise the
consumer tools use `node` from `PATH`.

## Complete validation

```sh
dart format --output=none --set-exit-if-changed lib test tool
dart analyze --fatal-infos
dart test
dart test --platform node --compiler dart2wasm \
  test/runtime/resources_test.dart \
  test/runtime/streams_test.dart \
  test/runtime/cancellation_test.dart
dart run tool/verify.dart
dart run tool/check_package.dart
python3 -m unittest discover -s .github/scripts -p 'test_*.py'
git diff --check
```

`dart test` discovers the complete Dart test suite. The explicit Node command
also checks the runtime suites compiled with Dart2Wasm. `tool/verify.dart` builds
the consumer fixtures and exercises their runtime, TypeScript and installed
package contracts. Each fixture's artifacts are reused across the selected
Node versions rather than rebuilding for each runtime.

`tool/check_package.dart` performs a publication dry-run, not an upload. It
accepts only the known warning about the intentionally pinned analyzer version;
other package-validation failures remain errors.

## Running the CI shards locally

CI distributes Dart suites and consumer fixtures across two runners. Both
indices are needed to reproduce complete coverage:

```sh
dart test --total-shards 2 --shard-index 0 --shard-by-suite
dart test --total-shards 2 --shard-index 1 --shard-by-suite

dart run tool/verify.dart --total-shards 2 --shard-index 0
dart run tool/verify.dart --total-shards 2 --shard-index 1
```

Dart sharding keeps each suite together and automatically discovers new test
files. Consumer sharding keeps each fixture's build and checks together. With
no shard arguments, both commands still run their complete set. Consumer logs
include the selected fixture names and elapsed time per fixture.

## Pull-request checks

Source, tests, tools, dependencies, workflows and mixed changes run full CI.
Every push to `main` also runs full CI. The publication tests additionally run
on macOS and Windows.

A pull request changing only ordinary, non-executable `doc/**/*.md` files may
skip the expensive test jobs. Static checks, package dry-run, whitespace checks
and the CI classifier's regression tests still run. Root Markdown files such as
`README.md`, `CHANGELOG.md` and `AGENTS.md` do not qualify. Missing history,
unknown paths, cross-boundary renames, symlinks and mode changes use full CI.
