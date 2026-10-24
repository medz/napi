# Dart Counter

Build a JavaScript package from Dart with [napi](https://github.com/medz/napi).
Use Dart 3.13.5 and Node.js 24.19.0 or 26.11.1.

From this directory:

```sh
dart pub get
dart run tool/build.dart
npm install ./npm-package
node example.mjs
```

The example prints `1` and `3`. Edit `lib/counter.dart` to change the Dart API.
`@NAPI()` exports the class, including its constructor, fields and methods.

The build declaration in `tool/build.dart` sets the npm package name, version,
output directory and backend. Change `name` and the import in `example.mjs` for
your own package. The Dart project name in `pubspec.yaml` is independent of the
npm name.

For a native Node-API addon, set `target: BuildTarget.native`, or select it for
one build:

```sh
dart run tool/build.dart --target native
```

Native builds download a matching runtime on first use; see
[supported platforms](https://github.com/medz/napi/blob/main/doc/native.md).
Wasm builds do not download a native runtime.

The build script can have any name. It is ordinary Dart code; use
`package.build()` when calling it programmatically, or `package.run(args)` to
expose its command-line options. Run it from the project directory so relative
paths resolve to this project.

To install the package elsewhere, create an npm tarball:

```sh
npm pack ./npm-package
```

Install that tarball in the consuming Node project. The package initializes
when imported and includes TypeScript declarations.
