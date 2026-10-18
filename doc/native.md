# Native Dart AOT bindings

The experimental native target runs ordinary Dart business code through a
precompiled Node-API bridge and a matching Dart AOT runtime. The current target
is macOS arm64 with Dart 3.13.5 stable. The builder downloads and caches the
matching runtime on first use; subsequent builds can use it offline.

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

The runtime download is about 1.9 MB and is pinned to its full SHA-256, size and
manifest hash. The cache defaults to `~/Library/Caches/napi`; set
`NAPI_RUNTIME_CACHE` to use another directory. Every use verifies the cached
files. A corrupt entry fails with its path so it can be removed before retrying;
download failures do not replace package output or trigger a local VM build.

For an offline build without a populated cache, pass
`nativeRuntime: Directory('/absolute/path/to/runtime-bundle')` to `buildLibrary`
or `buildPackage`. This override reads only that bundle. Native downloads happen
on the package author's machine during the build, never during npm installation
or import. The builder uses macOS's system `ditto` to extract the pinned archive.

## Supported bindings

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
Environment, live lease and actual selected-class membership are checked before business calls.
Readonly fields remain readonly and GC does not call business disposal methods.

The private bridge table is ABI 15 (57 slots). Its two bulk binary operations
copy valid input windows into Dart-owned storage and Dart output into independent
JS storage. The short acquired-pointer intervals contain no JS callbacks or
allocation. See [binary snapshots](binary.md) for the validity and ownership
contract; these operations do not implement live shared views.

Older bundles are rejected before copying. Consumer builds require only the
ordinary Dart SDK and the matching bundle; they do not rebuild the VM.
Constructor-target detection preserves custom JS subclass receivers during
canonical adoption. The reference-shape slot registers a composite wrapper creator only
after its observed interface combination passes the shared contract checks.
Ordinary class callbacks retain the existing path. Member callbacks validate Dart membership instead of V8's
exact Node-API constructor receiver restriction.

The compiler-private owned-value carrier retains any JS value without reflection
or coercion, including explicit `undefined`, `null`, symbols and functions. Its
token belongs to one native isolate owner; a borrowed handle lasts only for the
current callback scope. A lazily created Dart core Finalizer runs through the
existing owner-thread event pump and releases unreachable acyclic carriers.
It is bound to the root Zone so a business Zone cannot intercept that release.
Explicit release is idempotent, and environment teardown deletes remaining
references without invoking JS or business cleanup. Cross-heap cycles require
an explicit ownership break as described in the [architecture](architecture.md).
Generated [opaque bindings](opaque.md) use this internal primitive for supported
type parameters from the Dart declaration. Saved callback throws use the same
ownership mechanism, with no release queue or process-global reference registry.

List/Map/Dictionary/record functions and class members share Wasm's [structural conversion](structural.md)
contract, including nullable containers, cloned outputs, own-data fields, bounded
traversal and precise UTF-16 paths. Reflection uses JavaScript Array/prototype
semantics for Proxy inputs; lengths are captured once and descriptors are read
child by child. Handles stay scoped to the current callback; structural conversion
does not create a persistent container registry. Reference leaves reuse the same
class brands, weak identity cache and retained-object leases as direct calls.
Map input snapshots entries before recursive conversion; both directions reject
converted-key collisions. Each module captures six Map intrinsics and releases
their references with its existing isolate owner. Dictionary input uses own
string data properties and output has a null prototype; one captured
Object.create reference uses the same cleanup.

[Value classes](values.md) use explicit constructor mappings, recursive structural
data and separate input/output types. Inputs containing values validate a complete
parameter snapshot before Dart constructor materialization. All structural
outputs snapshot the complete Dart tree before host-side scalar, reference and
Map-key checks. These paths use temporary snapshot storage; output getters are
read once per occurrence before converting children.

Generated [callbacks](callbacks.md) retain ordinary typed functions through Dart
reachability and preserve adapter identity in a weak cache. Synchronous and
Future-returning exports accept them, including resource cleanup. A callback's
Future result requires a genuine JS Promise; its completion is queued for the
owning isolate without entering Dart from the JS reaction. Only async-callback
modules initialize this queue and completion entry point. Scalar/List/record/JS-handle
payloads share both targets' strict conversions. Exact JS failures survive Dart
catch/rethrow; per-invocation handles close after conversion and execution.

Unsupported shapes fail before output is created: general generic specialization
beyond generic payload storage, non-null
object defaults and general Future inputs/FutureOr. Direct
[AbortSignal inputs](cancellation.md) support cooperative Future cancellation and
owned Stream subscription cancellation; signal outputs and nested signals remain
unsupported. Callback outputs, optional/named callback parameters and callback
payloads beyond supported scalars/Lists/records/JS handles also remain unsupported. The same reference
contract runs on Wasm; see [reference classes](classes.md). A unique most-specific
selected class owns the canonical wrapper across base/interface views. Instance
prototypes inherit without static inheritance. Compatible unrelated selected
memberships use one private composite prototype with a complete instance
surface; conflicting call contracts fail before exposing a wrapper. Custom JS
prototypes retain priority. See the individual feature guides for unsupported
signatures and combinations.

## Runtime and verification

Each loaded module owns a Dart isolate on its Node environment's thread. Workers
receive separate isolates. Environment cleanup invalidates wrappers and shuts
down only its isolates. The process-wide VM and immutable snapshot mappings
remain resident, including after the last Worker unloads. Different-isolate
reentry is rejected while Dart is active. Dart-created child isolates and
interrupting non-returning synchronous Dart code are not supported.

Synchronous exports can schedule Dart microtasks, Futures, timers and receive-port
work. The bridge automatically delivers that work on the owning Node thread.
Microtasks queued by a synchronous export run after the current JavaScript call
stack, at the bridge's next event-loop checkpoint. Dart microtasks drain between
Dart messages; their ordering relative to JavaScript microtasks is not a shared
cross-backend Promise contract. An unresolved Dart Completer alone does not keep
Node alive; active Dart ports/timers do. Closing the environment cancels delivery
and releases its isolate without running business cleanup. Unhandled Dart async
errors are reported through Node's uncaught-exception path.

Generated [Stream exports](streams.md) use the Future delivery transport with a
private iterator wrapper. Admission owns a converted host
snapshot; delivery acknowledgement releases its envelope. Resource leases remain
attached to the original subscription until cancellation and accepted deliveries
finish.

Generated [Future-returning declarations](futures.md) use the same output
converters, keep receiver/argument roots through conversion and resolver delivery,
and return genuine Promises even for ordinary argument failures. Generated
[resource bindings](resources.md) share raw-object state, cache cleanup completion
and retain receiver/input leases through actual public Promise settlement.
Object results with nonempty resource leases use a private Node promise hook;
ordinary Future calls do not activate that observer.

The runtime's filename/install-name and bridge expectation encode the pinned
SDK/configuration and runtime source/input identity. The bridge checks the actual
linked identity before initializing the VM. Compatible installed copies can
share an image. Other runtime identities and platforms remain unqualified.
Both binaries target macOS 14; execution has been tested on macOS 14.8.9 and 27.0.1 arm64,
Node 24.19.0 and 26.11.1, Dart 3.13.5, Apple clang 21.0.0 and TypeScript 7.0.2.
Other macOS versions have not been tested.

```sh
dart run tool/native_verify.dart --packages-only
dart run tool/native_verify.dart /absolute/path/to/runtime-bundle
NAPI_TEST_NATIVE_RUNTIME=/absolute/path/to/runtime-bundle \
  dart test -P callback-native
```

The package-only command exercises automatic runtime acquisition and installed
native/dual packages. The explicit-bundle command runs the broader native suite.
CI runs the package-only checks on macOS arm64 with both Node versions; it does
not yet run the complete native suite. See [Running tests](testing.md).

The [distribution tool](../native/README.md#locked-distribution) lets maintainers
prepare a ZIP and lock for a runtime release. Its source provenance and archive
hash identify the exact inputs and payload; they do not establish a reproducible
upstream VM/toolchain build. Additional native platforms and automatic backend
fallback are not supported.

## Measured cost

The comparisons below describe the stated runtime ABI versions and small Dart
programs. They are historical measurements, not measurements of every current
feature combination. Protocols and limitations accompany each result.

A local macOS arm64 run on 2026-10-17 measured the same Dart
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

### Event-loop integration

The ABI 9 event pump was compared with the ABI 8 runtime on the same
machine, holding the generated `add`/`Counter` AOT, loader and declaration bytes
identical to isolate runtime costs. Each Node version ran two
same-target samples followed by three balanced AB/BA rounds in fresh processes.
Each sample warmed 20,000 calls, measured 300,000 function/getter/method calls,
20,000 constructions and 500 event-loop turns with 100 calls per turn.

| Node | Function ns, before → after | Method ns, before → after | Import ms, before → after |
| --- | ---: | ---: | ---: |
| 24.19.0 | 903.4 → 910.5 | 764.6 → 754.3 | 3.92 → 3.83 |
| 26.11.1 | 922.4 → 906.9 | 769.4 → 768.7 | 6.77 → 6.45 |

The Node 24 function median increased 0.78% (about 7 ns), in all six pairs;
same-target variation reached 6.71%. Node 26's function median decreased 1.68%
with mixed paired directions. Its constructor median increased 2.30%, while
same-target variation reached 12.38%. First-import filesystem effects were
large; these local samples are not a predictable cold-start or zero-regression
claim. The per-turn medians decreased 9.1–10.3%, without a general speed claim.

The bridge increased by 18,224 bytes; complete artifacts increased from
6,566,272 to 6,584,496 bytes (+0.28%). The implementation adds one async
handle/context per module
and coalesces synchronous calls into one pending drain; it adds no polling loop.

### Future transport and synchronous modules

The ABI 10 Future transport was compared with the ABI 9 runtime
using the same synchronous `add`/`Counter` business source and the event-loop
measurement protocol above. Changing the private table length requires a new
AOT snapshot, so this comparison includes regenerated AOT and the bridge;
it does not isolate bridge-only costs. Native loader/declaration bytes remain
identical. Wasm artifacts for this synchronous sample are unchanged.

| Node | Function ns, before → after | Getter ns, before → after | Method ns, before → after |
| --- | ---: | ---: | ---: |
| 24.19.0 | 907.8 → 902.8 | 765.3 → 759.9 | 763.9 → 762.4 |
| 26.11.1 | 913.5 → 915.2 | 763.4 → 779.6 | 776.4 → 776.4 |

The Node 26 getter median increased 2.12% (about 16 ns), in five of six pairs;
its baseline A/A variation was 4.52%. Node 24's getter decreased 0.71%.
Constructor medians changed +0.72%/-2.04%, while A/A variation reached 11.97%.
Function A/A variation reached 9.04%; cold-import and system noise remain
uncontrolled. These samples do not establish a speed improvement or zero
regression.

Complete native artifacts grow from 6,584,496 to 6,585,876 bytes (+1,380 bytes,
0.02%): bridge +1,264 bytes, AOT +112 bytes and manifest +4 bytes. The shared
runtime size is unchanged. Promise factories and Dart retention state are
generated only for modules with Future exports; this synchronous comparison
does not measure Future throughput or claim zero async allocation cost.

### Resource bindings and synchronous modules

The ABI 11 resource bridge was compared with the ABI 10 runtime
using the same synchronous `add`/`Counter` source and the A/A plus three balanced
AB/BA protocol above. AOT was regenerated for the private ABI change. Complete
artifacts grow from 6,585,876 to 6,587,844 bytes (+1,968 bytes, 0.03%), all in the
bridge; AOT/runtime sizes and loader/declaration bytes are unchanged. All eight
compiled Wasm artifacts for this resource-free sample remain byte-identical.

| Node | Function ns, before → after | Getter ns, before → after | Method ns, before → after |
| --- | ---: | ---: | ---: |
| 24.19.0 | 923.0 → 927.9 | 779.4 → 779.8 | 774.3 → 778.0 |
| 26.11.1 | 924.1 → 937.3 | 783.8 → 791.8 | 779.6 → 792.6 |

Call median changes range from +0.05% to +1.67%, with mixed paired directions
and same-target variation up to 3.56%. Constructor medians change +2.97%/-1.27%,
while same-target variation reaches 8.09%. Initial filesystem/signature checks
strongly affect first import; neither predictable cold-start latency nor zero
regression is established.
These synchronous measurements exclude active resource leases and Promise-hook
cost; see [resource measurement scope](resources.md#settlement-observer-cost).

### Owned values and synchronous modules

ABI 12 was compared with the preserved ABI 11 sample using the same synchronous
`add`/`Counter` source and A/A plus three balanced AB/BA rounds. AOT was regenerated
for the table length. Complete artifacts grow from 6,587,844 to 6,588,276 bytes
(+432 bytes, 0.007%), all in the bridge. AOT/runtime sizes and loader/declaration
bytes are unchanged. The owner has an empty map until a value is retained;
unused modules do not initialize the Dart Finalizer or its FFI functions.

| Node | Function ns, before → after | Getter ns, before → after | Method ns, before → after |
| --- | ---: | ---: | ---: |
| 24.19.0 | 920.7 → 937.5 | 774.9 → 785.7 | 785.1 → 782.9 |
| 26.11.1 | 918.6 → 917.5 | 770.7 → 762.8 | 775.2 → 767.8 |

Call medians changed from -1.03% to +1.82%, with mixed paired directions and
same-target variation up to 8.84%. Constructor medians decreased 2.02%/3.26%,
while same-target variation reached 19.23%. These local samples establish
neither a speed improvement nor zero regression. They exclude active owned-value
allocation, retrieval and finalization throughput.
