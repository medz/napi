# Contributing

Use Dart 3.13.5 and Node.js 24.19.0 or 26.11.1. From the repository root:

```sh
dart pub get
```

## Checks

```sh
dart format --output=none --set-exit-if-changed lib tool
dart analyze --fatal-infos
dart run tool/check_package.dart
git diff --check
```

The package check is a publication dry-run.
