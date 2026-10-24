# Native Dart AOT bindings

The experimental native target runs Dart business code through a precompiled
Node-API bridge and a matching Dart AOT runtime. It supports macOS 14 or later on
arm64 or x64 and Linux arm64 or x64 with glibc 2.28 or later, using Dart **3.13.5**.
All supported hosts download and cache their precompiled runtime on first use.

## Build a package

```dart
// lib/counter.dart
import 'package:napi/napi.dart';

@NAPI()
class Counter {
  int value;
  Counter([this.value = 0]);
  int increment([int amount = 1]) => value += amount;
}
```

```dart
// tool/build.dart
import 'dart:io';
import 'package:napi/build.dart';

Future<void> main() async {
  await buildPackage(
    library: File('lib/counter.dart').absolute.uri,
    output: Directory('npm-package'),
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    target: BuildTarget.native,
    metadata: {'name': '@scope/counter', 'version': '1.0.0'},
  );
}
```

Run `dart run tool/build.dart`, then pack and install `npm-package` in the Node
application:

```js
import { Counter } from '@scope/counter';
const counter = new Counter();
counter.increment(); // 1, executed in Dart
counter.value = 10;
```

Application builds use the ordinary Dart SDK. Extracting an uncached runtime on
Linux also needs `/usr/bin/unzip`.
C/C++ tools and SDK sources are needed only to produce a new runtime bundle;
see the [maintainer guide](../native/README.md).

The bundle and the Dart AOT compiler must match the build host. Cross-compiling
and musl-based distributions such as Alpine are not supported. npm consumers
need only the generated package and Node.js.

## Runtime download and offline builds

Runtime archive SHA-256, size and manifest hash are pinned in napi; cached
payload files are verified on every use. The cache defaults to:

- macOS: `~/Library/Caches/napi`.
- Linux: `$XDG_CACHE_HOME/napi` when `XDG_CACHE_HOME` is an absolute path,
  otherwise `~/.cache/napi`.

Set `NAPI_RUNTIME_CACHE` to select another directory on either platform. A
populated cache supports offline builds. A corrupt entry fails with its path
so it can be removed before retrying. Download failures leave package output
unchanged.

For an offline build without a populated cache, pass
`nativeRuntime: Directory('/absolute/path/to/runtime-bundle')` to `buildPackage`
or `buildLibrary`. This override reads only that bundle. Runtime downloads
happen during the author's build, never during npm installation or import.
The builder extracts the pinned archive with macOS's system `ditto` or Linux's
`unzip`. A local bundle does not need an archive extractor.

## Package contents

Native outputs contain `module.mjs`, `module.d.mts`, business `module.aot`,
`bridge.node`, the identity-qualified runtime, its manifest and licenses.
Single-target npm root and `./native` exports point to the same entry. Assembly
sets `os` and `cpu` from the runtime bundle, plus `libc: ["glibc"]` for Linux,
and rejects conflicting metadata.
Keep the complete file set and the Dart/napi licenses when redistributing.

The builder validates the exact compiler revision and runtime bundle before
compiling Dart AOT. Native analysis selects AOT conditional imports:
`dart.library.ffi` and `.io` are true; `.mirrors` and JS libraries are absent.
[External selections](annotations.md#bind-an-existing-library) use the same mapping.
See [npm packaging](packaging.md) for fresh output, managed rebuilds and explicit
dual-target packages.

## Supported bindings

Native and Wasm share [scalar conversion](scalars.md),
[argument presence and defaults](arguments.md), [structural values](structural.md),
[value classes](values.md), [reference classes](classes.md),
[generic payloads](opaque.md) and [concrete generic aliases](concrete-generics.md).
Both also support [binary snapshots](binary.md), [shared byte views](shared-bytes.md),
[JS collection handles](collections.md), [Futures](futures.md),
[callbacks](callbacks.md), [streams](streams.md), [cancellation](cancellation.md)
and [resource cleanup](resources.md).

The feature guides describe supported combinations and limits. Unsupported
signatures produce build diagnostics before output is published. Returning a
live reference reuses its wrapper; a collected wrapper can later be recreated
for the same Dart object without invoking its business constructor. Readonly
fields remain readonly, and GC does not call business disposal methods.

## Runtime behavior

Each loaded module owns a Dart isolate on its Node environment's thread.
Workers receive separate isolates. Cleanup invalidates wrappers and shuts down
only that environment's isolates. The process-wide VM and immutable snapshot
mappings remain resident after the last Worker unloads. Compatible installed
copies can share a runtime image; incompatible runtime identities are rejected.

Synchronous exports can schedule Dart microtasks, Futures, timers and receive-port
work. The bridge delivers that work on the owning Node thread. Dart microtasks
queued by a synchronous call run after the current JavaScript stack, at the next
bridge event-loop checkpoint. Their order relative to JS microtasks is not a
shared cross-backend ordering guarantee. Active Dart ports and timers keep Node
alive; an unresolved Dart Completer alone does not. Unhandled Dart async errors
reach Node's uncaught-exception path.

JS callback results and Future settlements are delivered through the owning
isolate. Pending operations retain the references required by their
[Future](futures.md) or [resource](resources.md) contract. Teardown releases
internal references without invoking JavaScript or business cleanup.

Native cycles spanning Dart and JavaScript require explicit ownership breaks,
such as clearing a stored value or unregistering a callback. See
[opaque ownership](opaque.md#ownership). Different-isolate reentry while Dart is
active, Dart-created child isolates and interruption of non-returning synchronous
Dart code are unsupported.

## Compatibility

The current bundle uses ABI 15 with Dart 3.13.5. Its embedding API and runtime
layout depend on experimental Dart internals; Node-API compatibility alone does
not make another Dart SDK or host interchangeable.

The macOS binaries target macOS 14. Execution has been tested on macOS 14.8.9
and 27.0.1 arm64, and macOS 15.7.9 x64, with Node 24.19.0 and 26.11.1 and
TypeScript 7.0.2 declarations. The macOS arm64 bundle was built with Apple
clang 21.0.0; the x64 bundle uses the pinned SDK clang/LLD 23 toolchain and
macOS SDK 15.5.

Linux arm64 and x64 bundles target glibc 2.28 and use the pinned Dart SDK
clang 23.0.0git toolchain and Debian sysroot. Execution has been tested on
Ubuntu 24.04 arm64 and x64 with Node 24.19.0 and 26.11.1 and TypeScript 7.0.2.
Node.js has its own operating-system requirements.
Windows, musl-based Linux and other Node-API hosts are not qualified.

See [the runtime bundle guide](../native/README.md) to build a new runtime
profile, and [CONTRIBUTING.md](../CONTRIBUTING.md) to run native tests.
