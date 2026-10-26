# napi

Node-API bindings for Dart.

## Native compilation

Use your own Dart build script:

```dart
import 'dart:io';
import 'package:napi/compiler.dart';

final compiler = Compiler([
  NativeTarget(
    entry: File('lib/addon.dart'),
    output: File('dist/addon.node'),
    node: '^24.0.0',
  ),
]);

Future<void> main(List<String> args) => compiler.run(args);
```

The output is a standalone `.node` file for the current platform. The package
includes compilers for macOS arm64, Linux arm64 and Windows x64; building an
addon does not require SDK sources or a C/C++ toolchain. Business code is compiled
with the bundled Dart 3.13.5 SDK, independently of the SDK running the script.

Omit `node` to infer the minimum requirements from referenced APIs. A supplied
range uses Dart version constraint syntax, with `||` for alternatives, and must
be compatible with those APIs. Compilation failures preserve an existing output.

`NativeTarget` currently accepts the low-level `initialize`, `afterPump` and
`dispose` entry contract used by the [native example](experiments/native-image/payload.dart).
Annotation-based exports are not implemented yet.

## Raw bindings

Import the raw FFI bindings with:

```dart
import 'package:napi/sys/node.dart' as node;
```

These bindings expose Node-API handles, status codes and native function
signatures. Calls require a valid environment supplied by a Node-API host.

See the [native image experiment](experiments/native-image/README.md) for the
standalone Dart AOT addon prototype.
