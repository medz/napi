# Running tests

Use Dart 3.13.5 and Node.js 24.19.0. CI also checks generated consumers with
Node.js 26.11.1. Install package and TypeScript dependencies from the repository
root (the test runner requires at least `test` 1.33.0):

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
dart test -P callback-wasm
dart run tool/verify.dart
dart run tool/check_package.dart
python3 -m unittest discover -s .github/scripts -p 'test_*.py'
git diff --check
```

`dart test` discovers the existing compiler, harness and runtime suites through
`dart_test.yaml`. Callback consumers are separate presets so ordinary discovery
and the legacy consumer tools do not build them twice. The explicit Node command
also checks the runtime suites compiled with Dart2Wasm. `tool/verify.dart`
continues to run the other consumer fixtures.

## Callback consumer suites

```sh
dart test -P callback-wasm
NAPI_TEST_NATIVE_RUNTIME=/absolute/path/to/qualified-bundle \
  dart test -P callback-native
# Select one fresh-process scenario; setUpAll still builds the two packages once.
dart test -P callback-wasm --name '^callback wasm Node 1 exact-errors$'
```

Each preset builds source and external packages once, packs them, removes the
build project, and installs the relocated archives offline in `setUpAll`.
The 26 runtime scenarios are independent tests for each configured Node.
With Node 24 and 26, both backends cover 104 scenarios, including the expected
late-rejection failure and Worker teardown. TypeScript checks all eight
NodeNext/Bundler × exact optional × strict function configurations once per
backend (16 checks, rather than repeating 32 across the runtime matrix).
The TypeScript host is `NAPI_TEST_NODE`, or `node` from `PATH`; it is independent
of `NAPI_NODE_EXECUTABLES` and its version is logged. CI uses Node 24 from `PATH`.

The native preset fails if `NAPI_TEST_NATIVE_RUNTIME` is missing or its bundle
validation fails; it does not skip, download an SDK, or build a VM. The existing
native verification command still covers the other consumers and should be run
with the same qualified bundle. Wasm callback CI runs the preset once in consumer
shard 0. Native callback verification currently remains an explicit local gate.

Each Node scenario runs with a 30-second command deadline, below the 45-second
test timeout, and drains output/reaps the direct child before cleanup. Only the
late-rejection case allows a positive nonzero exit, and it must contain its
specific marker; a signal, startup failure or timeout cannot satisfy it. Owned
fixture directories are removed after settled tests, including failures.
Compiler/npm commands still use the existing build path; TypeScript 7 can also
spawn its native compiler when execve is unavailable, so its fixed-host checks
keep that path as well. Process-tree timeout and cancellation remain unfinished
in #200. A test timeout does not imply those descendants have exited, so an
unsettled build or typecheck retains its directory.
The macOS guardian experiment is not installed as a wrapper for these tests.

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
