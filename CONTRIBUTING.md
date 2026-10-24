# Contributing

Use Dart 3.13.5 and Node.js 24.19.0 or 26.11.1. From the repository root:

```sh
dart pub get
npm install --prefix .dart_tool/js --no-save --no-package-lock \
  --ignore-scripts --no-audit --no-fund typescript@7.0.2
```

## Tests

```sh
dart test
dart test -P wasm-consumers
dart test --platform node --compiler dart2wasm \
  test/runtime/resources_test.dart test/runtime/streams_test.dart \
  test/runtime/callback_stream_test.dart test/runtime/cancellation_test.dart
```

Select tests with their path or `--name`. Consumer commands use `node`
from `PATH`; set `NAPI_NODE_EXECUTABLES` to a JSON array of absolute executable
paths to run them with more than one Node version.

On macOS arm64/x64 or Linux arm64/x64 with glibc 2.28 or later, run native and
dual-target consumers with:

```sh
dart test -P native-consumers
```

The runtime downloads automatically; extracting it on Linux needs `/usr/bin/unzip`. To use an
existing bundle offline, pass a matching bundle:

```sh
NAPI_TEST_NATIVE_RUNTIME=/absolute/path/to/runtime-bundle \
  dart test -P native-consumers
```

See [native builds](doc/native.md#runtime-download-and-offline-builds) for cache
locations, or the [runtime maintainer guide](native/README.md) to build a bundle.

## Checks

```sh
dart format --output=none --set-exit-if-changed lib test tool
dart analyze --fatal-infos
dart run tool/check_package.dart
python3 -B -m unittest discover -s .github/scripts -p 'test_*.py'
python3 -B -m unittest discover -s test/native -p '*_test.py'
git diff --check
```

The package check is a publication dry-run. Linux metadata tests also use
Python 3; ownership-failure checks need passwordless `sudo chown` in CI.
