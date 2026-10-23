# napi

A Dart binding compiler for native Node-API `.node` addons and Dart Wasm.
Declare an API in Dart, build an npm package, and import it normally:

```dart
// lib/counter.dart
import 'package:napi/napi.dart';

@NAPI()
class Counter {
  int value;
  Counter([this.value = 1]);
  Counter.seed(this.value);
  int increment([int amount = 1]) => value += amount;
}
```

```js
import { Counter } from '@scope/counter';
const counter = new Counter();
counter.increment(); // 2, executed in Dart
```

`@scope/counter` is the example package built below. Imports initialize the
selected backend; consumers do not register bindings or call application `main`.

The compiler follows napi-rs's binding model: one Dart declaration and matching
JavaScript/TypeScript APIs for native and Wasm targets. Business logic runs in
Dart; generated loaders initialize the selected backend on import.

## Supported bindings

| API | Guide |
| --- | --- |
| Functions, optional/named arguments, defaults and strict scalar conversions | [Annotations](doc/annotations.md), [arguments](doc/arguments.md), [scalars](doc/scalars.md) |
| Lists, Maps, dictionaries, records and value classes | [Structural values](doc/structural.md), [value classes](doc/values.md) |
| Classes, inheritance, object identity and generics | [Classes](doc/classes.md), [generic payloads](doc/opaque.md), [concrete aliases](doc/concrete-generics.md) |
| Copied bytes, shared byte views and JS collection handles | [Binary data](doc/binary.md), [SharedBytes](doc/shared-bytes.md), [collections](doc/collections.md) |
| Futures, callbacks, streams, cancellation and resource disposal | [Futures](doc/futures.md), [callbacks](doc/callbacks.md), [streams](doc/streams.md), [cancellation](doc/cancellation.md), [resources](doc/resources.md) |
| Unmodified third-party Dart libraries | [External selections](doc/annotations.md#external-selections) |

The guides describe supported combinations. Unsupported signatures produce
build diagnostics. Wasm is the default target; native currently supports macOS
arm64. Dual packages expose explicit `/native` and `/wasm` entries, with the root
backend chosen at build time. There is no automatic platform selection or
fallback between backends.

## Build a package

Use Dart **3.13.5** and add the package:

```sh
dart pub add napi
```

Annotated sources import `package:napi/napi.dart`. A separate Dart VM script
builds the npm package:

```dart
// tool/build.dart
import 'dart:io';
import 'package:napi/build.dart';

Future<void> main() async {
  await buildPackage(
    library: File('lib/counter.dart').absolute.uri,
    output: Directory('npm-package'),
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    metadata: {'name': '@scope/counter', 'version': '0.0.0'},
  );
}
```

Run `dart run tool/build.dart`, then pack/install `npm-package` in the Node
consumer. Use a new output path, or follow the [managed rebuild rules](doc/packaging.md#managed-rebuilds)
for a package created by this builder on local macOS APFS or supported 64-bit
Linux filesystems.
For native, supply `target: BuildTarget.native`; the builder downloads and caches
the matching precompiled runtime. See [native prerequisites](doc/native.md) and
[explicit dual-target builds](doc/packaging.md#explicit-dual-target-packages).
Use [external selections](doc/annotations.md#external-selections) for unmodified
Dart dependencies, or `buildLibrary` when raw artifacts are wanted.
See [migration notes](doc/annotations.md#migrating-earlier-bindings) for the
former annotation, container and runtime assumptions.

## Scalar conversions

The same conversion rules apply to package imports on both targets. The example
below uses the supported direct-Wasm path; ship its generated dependencies too.

```dart
import 'package:napi/napi.dart';

@NAPI()
String? echo(String? value) => value;

@NAPI(bigint: true)
int addWide(int left, int right) => left + right;
```

```js
import { echo, addWide } from './module.wasm';
echo(null);           // null
echo('🙂');           // '🙂'
addWide(1n, 2n);      // 3n
```

Conversions never coerce input values. Required nullable parameters accept `null`, but not
`undefined` or omission. Optional parameters default for omission and `undefined`.
`double` preserves NaN, infinities and negative zero;
strings preserve UTF-16 code units, including lone surrogates. Default `int`
checks the JavaScript safe-integer range in both directions. The `bigint` option
maps all Dart `int` inputs/results of that function to JavaScript `bigint` with a
signed 64-bit input range; Dart `BigInt` always uses arbitrary-precision JavaScript
`bigint`. See [the full contract](doc/scalars.md), including error behavior.

## Verify

The tested toolchain is Dart **3.13.5 stable**, Node **24.19.0** and **26.11.1**,
and TypeScript **7.0.2**. The SDK adapter rejects other Dart versions because it
uses experimental compiler interfaces. Native builds currently support macOS
arm64; see [native compatibility](doc/native.md#compatibility). Bun and browser
compatibility are unverified.

See [Running tests](doc/testing.md) for dependencies, test commands, Node version
selection and native runtime setup. See [the architecture](doc/architecture.md)
and [Wasm backend design](doc/foundation.md) for compiler and runtime boundaries.

Relative `.wasm` imports use a sibling `module.d.wasm.ts` and TypeScript's
`allowArbitraryExtensions` option. A single-target Wasm package's root and
`./module.wasm` subpath both resolve directly to the Wasm file.

## License

MIT. See [LICENSE](LICENSE). Generated Dart runtime helpers originate in the Dart
SDK. Generated artifacts include its license as `DART_LICENSE`; distributors
must retain that notice.
