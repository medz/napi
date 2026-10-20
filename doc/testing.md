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

## Run the suites

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

`dart test` discovers compiler, harness and runtime suites through
`dart_test.yaml`. Callback consumers use separate presets; `tool/verify.dart`
runs the other consumer fixtures. The `--platform node --compiler dart2wasm` command runs the shared runtime
suites compiled to Wasm.

## Native consumers

On macOS arm64, run all native consumers, dual-target packages and callbacks with
automatic runtime acquisition:

```sh
dart run tool/native_verify.dart
```

`NAPI_RUNTIME_CACHE` selects the cache directory. The first native build downloads
the pinned runtime; the remaining builds reuse the verified bundle. Dual-target
packages also check offline cache reuse. Each fixture is built and installed
once, then checked with every configured Node version. CI runs the complete
suite on macOS 14 with both Node versions.

For an offline run, supply a qualified bundle:

```sh
dart run tool/native_verify.dart /absolute/path/to/runtime-bundle
```

`--packages-only` runs just the native package and dual-target package checks,
with the same optional bundle argument. The host-value fixture exercises a
handwritten private ABI module; it does not test generated opaque declarations.

The download/cache tests use `NAPI_TEST_RUNTIME_ARCHIVE` for the published ZIP.
Without it, ordinary test discovery skips the successful-download cases. The
native CI job supplies it and fails if the archive cannot be obtained.

## Callback consumer suites

```sh
dart test -P callback-wasm
NAPI_TEST_NATIVE_RUNTIME=/absolute/path/to/qualified-bundle \
  dart test -P callback-native
# Select one fresh-process scenario; setUpAll still builds the two packages once.
dart test -P callback-wasm --name '^callback wasm Node 1 exact-errors$'
```

Each preset builds and installs source and external packages once, then runs
its scenarios on each configured Node executable. TypeScript checks run once
per backend in NodeNext and Bundler modes. Set `NAPI_TEST_NODE` to choose the
TypeScript host; otherwise it uses `node` from `PATH`, independently of
`NAPI_NODE_EXECUTABLES`.

When run directly, the native preset requires `NAPI_TEST_NATIVE_RUNTIME` to name
a valid runtime bundle. The complete native verification command above obtains
the bundle and runs this preset automatically. CI runs both callback backends.

Callback Node scenarios have command deadlines and clean up their child
processes. Compiler/npm/TypeScript process-tree cancellation is not implemented;
a test timeout may leave a build or typecheck process running.

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
