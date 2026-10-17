# Native AOT runtime bundle

The native compiler uses one maintainer-built bridge and runtime for each
supported platform profile. Consumer business code is compiled only as Dart
AOT; consumers do not compile C/C++ or initialize the runtime manually.
The current profile is Dart **3.13.5**, revision
`04bcd1036cdc799ac6564988f159ee454d42c822`, **macOS arm64 Product**, uncompressed
pointers, no sanitizers/dynamic modules, and deployment target **14.0**.
Other profiles fail explicitly.

## Maintainer build

Prerequisites are an existing checkout of that exact SDK with its dependencies,
a prepared Product VM build cache, Xcode command-line tools, Python 3, and local
Node and libuv headers. Nothing here downloads or bootstraps the SDK/toolchain. A bare SDK
checkout alone is insufficient.
The builder looks for `uv.h` alongside the Node headers, then in their parent
directory for installations that separate Node and libuv headers. Missing
headers fail explicitly. The current macOS profile uses system Apple clang and
local Node/libuv headers; runtime behavior is validated separately on Node 24
and Node 26, including fresh packages, workers and teardown.

To prepare a cache, copy `native/runtime/` into the SDK as `runtime/napi/` in a
checkout where that directory does not already exist. Do not overwrite an
unrelated SDK customization. The included `BUILD.gn` follows the pinned SDK's
`runtime/engine/BUILD.gn` and provides the `napi_runtime` cache-preparation target.
Use existing local GN/Ninja tools; do not use a wrapper that downloads tools:

```sh
"$SDK_SOURCE/buildtools/gn" gen "$VM_CACHE" \
  --root-target=//runtime/napi:napi_runtime \
  --args='target_os="mac" host_cpu="arm64" target_cpu="arm64" dart_target_arch="arm64" is_debug=false is_release=false is_product=true dart_debug=false dart_runtime_mode="release" dart_use_compressed_pointers=false dart_use_crashpad=false dart_dynamic_modules=false is_asan=false is_lsan=false is_msan=false is_tsan=false is_ubsan=false is_hwasan=false mac_sdk_min="14.0"'
"$LOCAL_NINJA" -C "$VM_CACHE" napi_runtime
```

That first SDK build can compile VM objects. The bundle command below reuses
them, checks the SDK revision and actual `args.gn` configuration, and checks the
cache's compiler deployment target. It compiles the repository's `runtime.cc`
and `identity.cc`, replacing the cached candidate runtime object, then compiles
one generic bridge. It neither modifies the SDK/cache nor recompiles VM objects:

```sh
python3 tool/native/build.py \
  --sdk "$SDK_SOURCE" \
  --runtime-build "$VM_CACHE" \
  --node-headers "$NODE_HEADERS" \
  --output "$NEW_BUNDLE_DIRECTORY"
```

The output must not exist. Compilation finishes in a sibling staging directory
and an atomic no-replace rename publishes the bundle. Failed builds remove only
their own staging files. Existing output, SDK objects and other bundles remain
untouched. Node headers affect the reusable bridge, not individual businesses.

## Bundle contract

The flat bundle contains `bridge.node`, the identity-qualified runtime dylib,
`DART_LICENSE`, `DART_AUTHORS`, `NAPI_LICENSE`, and `manifest.json`.
The manifest has `format: 1`, `sdkVersion`, `sdkRevision`, `platform: "macos"`,
`architecture: "arm64"`, `minimumOsVersion: "14.0"`, `abi: 9`, `identity`,
`bridge`, `runtime`, and `files` mapping the five payload names to SHA-256 hashes.
Its `build` evidence records the cache arguments hash, combined input-object
digest/count, and runtime/ABI source hash. It contains no local SDK paths.
The consumer build validates this manifest and hashes before copying its exact
file whitelist. The final binary hash is asset evidence, not runtime identity.

The stable runtime identity includes the pinned SDK revision, mode, architecture,
ABI and a combined digest of the runtime/bridge ABI source hash and VM input
objects digest. Distinct VM caches cannot silently share an identity merely
because their Git HEAD matches. The runtime filename/install-name contain
it. The bridge compares the actual linked `NapiDart_RuntimeIdentity()` result
with its compiled expected identity before any VM initialization. Compatible
copies may share one loaded image; an unused local copy is not inspected.
Different actual identities fail. Pack/manifest validation owns asset integrity.
Both native images use deployment target 14.0; the bridge resolves its sole
runtime dependency through `@loader_path`, without an SDK/developer path.

## ABI and lifecycle

`runtime/runtime.h` declares nine runtime operations. The pure identity query
returns a borrowed immutable string and does not initialize the VM. The other
operations initialize, load immutable canonical AOT snapshots, create/enter/exit
isolates, drain microtasks, free errors and shut down one isolate. Public Dart C
APIs provide scopes, values, invocation and persistent handles while entered.

`bridge/abi.h` fixes the 43-slot compiler-private table and binding metadata.
`napiBindings(address, count)` must validate that count before reading the table.
Functions/classes retain actual JS call presence and `new` behavior. Getter and
setter closures share one JS property descriptor but remain distinct callbacks.
Named options use own-data descriptors; sparse positional values remain supplied
`undefined`, and optional/default decisions stay in generated Dart.

Slots 28 and 29 look up a weak wrapper by lease and adopt a new wrapper through
its original captured constructor. Adoption bypasses business construction.
A zero-count Node-API reference and Dart Expando cache preserve identity without
rooting a wrapper. Each replacement wrapper receives a new lease; delayed old
finalizers release only their own retained Dart object. The selected public class
identity stays attached to the Dart object while it is alive.

Slots 30–34 inspect one structural container, read one own-data child, compare
JS identity, create an output container, and define one own-data value. They use
callback-scoped handles. Generated Dart traversal owns the per-root depth/work
budget and active ancestor list; C does not retain structural schemas or values.
Array/prototype reflection follows JavaScript semantics, including Proxy traps,
and preserves original pending exceptions. Error paths and keys retain UTF-16.

Slots 35–37 snapshot genuine Map entries, create an output Map, and insert an
entry only when its converted key is absent. Input snapshotting finishes before
child conversion; both keys and values count toward the structural work limit.
Each isolate owner captures six Map intrinsics and releases those references
through its existing cleanup. Map entries use callback-scoped handles, without
a persistent container registry.

Slots 38 and 39 validate and snapshot Dictionary string keys and create a
null-prototype output object. Dictionary keys are field metadata; only the root
and recursively converted values count toward the work budget. Descriptor reads
remain in slot 31 and safe own-property writes remain in slot 34. One additional
captured Object.create reference follows the existing owner cleanup.

Slot 40 reads one optional own-data property using one descriptor lookup. A
missing property returns a null native handle; present JavaScript `undefined`
and `null` retain real handles. Accessors and reflection exceptions follow slot
31. Generated value-class conversion keeps presence/default decisions in Dart
and does not retain this callback-scoped handle across calls.

Every Node environment owns its isolates and persistent handles. Cross-owner
receivers and different-isolate reentry are rejected; GC during active callbacks defers
owner release until a safe outer boundary. Each owner automatically initializes
one libuv async handle. VM notifications only increment an atomic message count
and wake the Node thread; coalesced libuv wakeups cannot discard Dart messages.
Each turn handles at most 64 notifications, draining microtasks before messages
and after each message. The outermost Dart call also schedules a drain, because
pure microtasks do not send VM notifications. Repeated synchronous calls in one
turn share that scheduled drain; consumers do not initialize a scheduler.

A scheduled drain keeps Node alive until it runs. Afterward, live Dart ports or
remaining notifications keep the async handle referenced; an unresolved Future
alone does not. Timers and ports use the pinned Dart runtime's existing event
handler. No polling thread or replacement timer implementation is introduced.
Node handle/callback scopes contain each pump, with Dart fully exited before
Node callback-scope close can run JS microtasks and reenter another owner.
Uncaught Dart event errors are reported as Node errors through
`napi_fatal_exception`; a throwing microtask schedules another drain for its
remaining queue. Normal Node uncaught-exception behavior applies.

An async environment cleanup hook invalidates wrappers, deletes persistent
handles while entered, exits, and shuts down only its own isolate. Shutdown
stops in-flight notifications before `uv_close`; queued wakeups retain their
owner until the close callback releases it and completes the cleanup hook.
Failed loads use the same shutdown/close sequence even before a cleanup hook
has been registered. Matching
runtime images stay resident with a retained `RTLD_NODELETE` handle because
there is no process-global VM shutdown. This protects worker-only unload/reload.

The ABI/runtime are coupled to private experimental Dart SDK internals:
embedder initialization, core-library setup and microtask draining. Future-returning
export generation, asynchronous resource cleanup, Dart-created child isolates,
non-returning Dart interruption,
cross-identity VM sharing and other platforms are outside this implementation.
Their acceptance remains open. `DART_LICENSE` and `DART_AUTHORS` retain the
upstream SDK license/attribution; original bridge code uses the package license.

Slot 41 compares actual `new.target` with the captured selected constructor; it
performs no mutable JavaScript property lookup. The compiler-private ABI is 9:
the table still has 43 slots, and the version now requires automatic event
scheduling and async environment cleanup. Older synchronous bundles are rejected.

Slot 42 registers a composite selected-interface shape through the generated
loader's private resolver. Only type IDs and a creator function are retained;
no business objects enter this metadata cache. Slot 29 reuses that creator for
a neutral plain wrapper, then attaches the ordinary weak native lease. Custom
`new.target` keeps its receiver prototype. Resolver references are released on
Owner teardown; failed registration publishes neither a Dart nor C shape.
