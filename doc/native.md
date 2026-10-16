# Native Dart AOT bindings

The experimental native target runs ordinary Dart business code through a
precompiled Node-API bridge and a matching Dart AOT runtime. The current target
is macOS arm64 with Dart 3.13.5 stable. A runtime bundle is supplied explicitly;
automatic runtime downloads, platform selection and backend fallback are not
implemented yet.

```dart
// counter.dart
import 'package:napi/napi.dart';

@NAPI()
class Counter {
  int value;
  Counter([this.value = 0]);
  int increment([int amount = 1]) => value += amount;
}
```

```dart
// build.dart — run with the ordinary Dart SDK
import 'dart:io';
import 'package:napi/build.dart';

Future<void> main() async {
  final built = await buildLibrary(
    library: File('counter.dart').absolute.uri,
    output: Directory('native-output'),
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    target: BuildTarget.native,
    nativeRuntime: Directory('runtime-bundle'),
  );
  await assembleNativePackage(
    module: built,
    output: Directory('npm-package'),
    metadata: {'name': '@scope/counter', 'version': '1.0.0'},
  );
}
```

```js
import {Counter} from '@scope/counter';
const counter = new Counter();
counter.increment(); // 1, executed in Dart
counter.value = 10;
```

The source and external-selection frontends share declaration metadata. Native
analysis selects AOT conditional imports (`dart.library.ffi` and `.io` are true;
`.mirrors` and JS libraries are absent). The builder checks the exact compiler
revision, validates the bundle's flat file allowlist and SHA-256 hashes, compiles
only Dart AOT, and publishes to a fresh directory atomically. It never invokes a
C compiler or fetches SDK sources. Runtime maintainers build the reusable bridge
and shared runtime as described in [the maintainer guide](../native/README.md).

Native outputs include an automatic `module.mjs` entry, `module.d.mts`, business
`module.aot`, `bridge.node`, the identity-qualified runtime, its manifest and
licenses. npm root and `./native` exports point to the same entry. Package
assembly sets `os: ["darwin"]` and `cpu: ["arm64"]`, rejects conflicting metadata,
and rechecks copied runtime integrity. There is no install script or manual
initialization. Preserve the Dart and napi licenses when redistributing.

## Implemented slice

Required, optional, named and nullable scalar calls share the Wasm
[scalar](scalars.md) and [presence](arguments.md) contracts. This includes
safe-integer numbers, signed 64-bit `int` with `bigint: true`, arbitrary `BigInt`,
exact UTF-16, booleans and IEEE-754 doubles. Boundary violations raise TypeError
or RangeError; ordinary Dart failures become Error, including a safe fallback
when the thrown object's string conversion fails.

Reference classes support unnamed generative/factory construction with `new`,
named constructors/factories as static methods, direct class arguments/results,
methods, fields, accessors and selection/renaming. Repeated returns reuse a live
wrapper. Wrapper collection releases its retained-object lease; a Dart-held object
can later acquire a fresh wrapper without another business constructor call.
Weak identity entries and zero-count Node-API references do not root wrappers.
Environment and exact selected class brands are checked before business calls.
Readonly fields remain readonly and GC does not call business disposal methods.

The private bridge table is ABI 2 (30 slots). Older bundles are rejected before
copying; maintainers rebuild the bridge/runtime bundle using their existing VM
cache. Consumer builds still require only the ordinary Dart SDK and that bundle.

Unsupported shapes fail before output is created: structural values on native,
nested references, value/resource policies, generic specialization, non-null
object defaults, Futures, callbacks, streams and cancellation. The same reference
contract runs on Wasm; see [reference classes](classes.md). JavaScript inheritance
is not generated, and one Dart object returned through different selected public
class types is rejected. The full class/lifetime roadmap remains open.

## Runtime and verification

Each loaded module owns a Dart isolate on its Node environment's thread. Workers
receive separate isolates. Environment cleanup invalidates wrappers and shuts
down only its isolates. The process-wide VM and immutable snapshot mappings
remain resident, including after the last Worker unloads. Different-isolate
reentry is rejected. Async scheduling, Dart-created child isolates and interrupting
non-returning synchronous Dart code are not supported by this slice.

The runtime's filename/install-name and bridge expectation encode the pinned
SDK/configuration and runtime source/input identity. The bridge checks the actual
linked identity before initializing the VM. Compatible installed copies can
share an image. Other runtime identities and platforms remain unqualified.
Both binaries target macOS 14; execution has been tested on macOS 27.0.1 arm64,
Node 24.19.0 and 26.11.1, Dart 3.13.5, Apple clang 21.0.0 and TypeScript 7.0.2.
The deployment target alone does not prove execution on older macOS releases.

```sh
dart run tool/native_verify.dart /absolute/path/to/runtime-bundle
```

This explicit native check runs the same scalar/argument assertions as Wasm,
builds a separate Dart consumer through the public API, packs and relocates the
native npm package, removes its original build/source directory, and installs
offline into a path with spaces and non-ASCII characters. It checks constructors,
properties, invalid receivers, retained state, GC, normal/terminated Workers,
Worker-only unload/reload, and TypeScript NodeNext/Bundler resolution. General CI
also checks native metadata, emission, AOT compilation and manifest validation;
the full native execution check requires a maintainer bundle and is run locally.

No binary is committed or released by this development change. Runtime supply
automation, additional targets, complete lifecycle engines and cross-backend
package selection remain required before a complete native milestone release.

## Measured cost

A local, non-frozen macOS arm64 run on 2026-10-17 measured the same Dart
`add(int, int)` declaration through both targets. Each Node version first ran
same-target A/A samples, then three balanced AB/BA rounds, using fresh child
processes, 20,000 warmup calls and 200,000 measured calls per sample. The table
shows medians of six balanced samples per target; warm time includes the JS loop
and scalar checks. RSS follows explicit GC and is process memory, not peak usage.

| Node | Target | Warm ns/call | Import ms | Import RSS increase MiB | Steady RSS MiB |
| --- | --- | ---: | ---: | ---: | ---: |
| 24.19.0 | Wasm | 63.7 | 2.12 | 4.60 | 57.08 |
| 24.19.0 | Native | 915.4 | 3.70 | 5.73 | 58.59 |
| 26.11.1 | Wasm | 61.4 | 2.11 | 1.16 | 17.42 |
| 26.11.1 | Native | 888.6 | 6.17 | 1.76 | 18.14 |

A/A warm differences were 20.0%/4.3% for Wasm/native on Node 24 and 1.5%/0.8%
on Node 26. Node 24's first native import took 1,482 ms; its second took 3.66 ms.
Filesystem caches, competing load and thermal state were uncontrolled, so these
observations do not establish statistical significance or predictable cold cost.

Complete artifacts, including runtime assets and licenses, totaled 109,514 bytes
for Wasm and 6,497,143 bytes for native. This native scalar path is slower and
larger and is currently not a performance optimization. Wasm remains the default;
the native target serves Node-API capability requirements.

Reproduce with `dart run tool/native_benchmark.dart <bundle> <node24> <node26>`.
The bounded run writes all raw samples, RSS deltas, artifact sizes and the exact
runtime manifest to a fresh temporary directory printed by the tool.
