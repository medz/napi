# napi

Build Node.js extensions in Dart. Export functions and classes, generate an npm
package, and call it from JavaScript or TypeScript. Choose Dart Wasm or a native
Node-API `.node` addon; both run your application code in Dart.

## Requirements

- Dart **3.13.5**.
- Node.js **24.19.0** or **26.11.1**.
- Native builds: macOS 14 or later on arm64. The precompiled runtime downloads
  automatically; application builds do not need a C/C++ toolchain.

Wasm is the default target. It depends on experimental Dart compiler and interop
APIs and is tied to Dart 3.13.5. Browser and Bun support is not yet verified.

## Build a package

Create a Dart package and add napi:

```sh
dart create -t package dart_counter
cd dart_counter
dart pub add napi
```

Write `lib/counter.dart`:

```dart
import 'package:napi/napi.dart';

@NAPI()
class Counter {
  Counter([this.value = 0]);
  int value;
  int increment([int amount = 1]) => value += amount;
}
```

Create `tool/build.dart`:

```dart
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

Build and install the generated package in the same directory:

```sh
dart run tool/build.dart
npm init -y
npm install ./npm-package
```

Create `example.mjs` and run it with `node example.mjs`:

```js
import {Counter} from '@scope/counter';

const counter = new Counter();
console.log(counter.increment());  // 1
console.log(counter.increment(2)); // 3
```

The package initializes when imported. TypeScript declarations are generated
alongside the bindings. To use the package in another Node project, run
`npm pack ./npm-package` and install the resulting tarball there.

For a native package, add `target: BuildTarget.native` to the `buildPackage`
call. See [native builds](doc/native.md) for runtime caching and offline builds,
and [packaging](doc/packaging.md) for dual-target packages and rebuilding output.

## Learn more

- [Export functions and classes](doc/annotations.md)
- [Parameters and defaults](doc/arguments.md) · [Numbers and strings](doc/scalars.md)
- [Classes](doc/classes.md) · [Plain objects](doc/values.md)
- [Lists, Maps and records](doc/structural.md) · [Shared JS collections](doc/collections.md)
- [Generic payloads](doc/opaque.md) · [Concrete generic aliases](doc/concrete-generics.md)
- [Promises](doc/futures.md) · [Callbacks](doc/callbacks.md) · [Streams](doc/streams.md)
- [Binary data](doc/binary.md) · [Shared bytes](doc/shared-bytes.md)
- [Resource cleanup](doc/resources.md) · [Cancellation](doc/cancellation.md)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) to run the tests.

## License

MIT. See [LICENSE](LICENSE). Generated packages include Dart's `DART_LICENSE`;
keep the included license notices when distributing them.
