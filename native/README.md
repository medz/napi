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
`architecture: "arm64"`, `minimumOsVersion: "14.0"`, `abi: 15`, `identity`,
`bridge`, `runtime`, and `files` mapping the five payload names to SHA-256 hashes.
Its `build` evidence records the cache arguments hash, combined input-object
digest/count, and runtime/ABI source hash. It contains no local SDK paths.
The consumer build validates this manifest and hashes before copying its exact
file whitelist. The final binary hash is asset evidence, not runtime identity.

New maintainer builds also write `build.provenance`: the producer commit and
explicit dirty-source flag, hashes of the repository's actual build inputs,
compiler identity and macOS SDK version, cache recipe hashes, and non-system
headers discovered with the compilation flags before compiling and checked
again against the actual compiler dependency files. Source, VM objects, cache
recipes and compiler hashes are also checked again before publication; detected
input drift fails the build. Keep the prepared cache and toolchain unchanged
while building. This detects accidental concurrent changes, not an adversarial
writer that changes and restores files between checks.
This record is created during the build. It must not be backfilled onto an older bundle. A dirty producer is
identified by its complete input hashes; it does not claim that the commit alone
reproduces those bytes. The existing `build.sourceSha256` remains the narrower
runtime identity input; it does not cover the complete bridge implementation.

## Locked distribution

Prepare a deterministic ZIP and lock from a newly built, validated bundle:

```sh
python3 tool/native/bundle.py pack /absolute/path/to/new-bundle \
  --archive /absolute/path/to/new-runtime.zip \
  --lock /absolute/path/to/new-bundle.lock.json
```

Both output paths must be new. This uses the ordinary Dart SDK to invoke the
same bundle validator used by application builds; it neither loads native code
nor compiles C/C++. The ZIP contains only the five payload files and manifest.
The lock binds the exact archive size/hash, manifest hash and SDK/runtime profile.
Its URL remains `null` until the reviewed archive has an approved fixed GitHub
release asset location. Preparing a lock does not upload or publish anything.
If the archive is published but a concurrent writer prevents lock publication,
the command fails and preserves the archive path; it does not delete a file that
another process may already have replaced. Inspect the reported paths and use
new output names when retrying.

For local review, supply that archive explicitly:

```sh
python3 tool/native/bundle.py fetch \
  --lock /absolute/path/to/new-bundle.lock.json \
  --archive /absolute/path/to/new-runtime.zip
```

The command prints the verified cache directory. Cache entries are keyed by the
archive SHA-256 and revalidated on every use, including the current repository's
complete native source inputs. A source mismatch, corrupt cache, missing source
or download failure is an error; it never triggers a VM build or selects another
runtime. Existing corrupt entries are preserved for diagnosis, not overwritten.
Archives are bounded and restricted to the exact flat regular-file inventory.

No remote asset or repository-default lock is supplied by this change. CI runs
the distribution regression tests using synthetic files and the real Dart
validator; these tests do not load a native runtime. Full native execution stays
an explicit maintainer check until a reviewed asset is published and the macOS
native job is added. An empty cache requires `--archive` when the lock URL is
`null`; a verified cache hit can still be reused. That later job must require a
verified remote source, not
skip native execution when the asset is unavailable. Standard application builds
retain their explicit `nativeRuntime` input and do not perform network requests.

Only maintainers prepare SDK sources and Product VM objects. Routine bridge or
runtime changes reuse that cache through `build.py`; consumer CI downloads the
small precompiled bundle, not the VM cache. A new full source fingerprint does
not itself require a new ABI or rebuilding the VM.

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

`bridge/abi.h` fixes the 57-slot compiler-private table and binding metadata.
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
embedder initialization, core-library setup and microtask draining. Dart-created child isolates,
non-returning Dart interruption,
cross-identity VM sharing and other platforms are outside this implementation.
Their acceptance remains open. `DART_LICENSE` and `DART_AUTHORS` retain the
upstream SDK license/attribution; original bridge code uses the package license.

Slot 41 compares actual `new.target` with the captured selected constructor; it
performs no mutable JavaScript property lookup. The compiler-private ABI is 15
with 57 slots. It retains the owner-thread event scheduling and async environment
cleanup introduced by ABI 9. Older bundles are rejected before copying.

Slot 42 registers a composite selected-interface shape through the generated
loader's private resolver. Only type IDs and a creator function are retained;
no business objects enter this metadata cache. Slot 29 reuses that creator for
a neutral plain wrapper, then attaches the ordinary weak native lease. Custom
`new.target` keeps its receiver prototype. Resolver references are released on
Owner teardown; failed registration publishes neither a Dart nor C shape.

Slot 43 queues one Promise settlement by owner-local token. Future callback
metadata appends a true flag and its Dart callback receives that token as a third
argument. Before entering Dart, the bridge creates a genuine Promise using the
loader's captured constructor and holds its private capability with an ordinary
Node-API reference. Conversion writes the payload into that capability; it never
keeps a callback-scoped handle across a Dart Future. The event pump calls the
resolver after leaving Dart, then acknowledges release of retained Dart
arguments/receiver roots. Resource calls with object results defer their lease
release until the public Promise settles, including thenable adoption. Teardown drops capability references without invoking
JavaScript. Sync-only modules do not install the factory or retain the Dart
Future entrypoint. See [Future contracts and remaining limits](../doc/futures.md).

The release entrypoint returns its retained argument list into the current native
Dart handle scope before discarding the pending record. That observable native
return prevents AOT from removing stores to an otherwise write-only roots field.
Fresh consumers verify that even orphaned pending business Futures retain their
arguments/receiver after the caller drops its Promise. The list is released with
the scope; this adds no permanent root or separate traversal.

Slot 44 binds a cleanup candidate to the raw ResourceControl's stable numeric
identity. Repeated valid calls return a live canonical Promise and discard their
unexposed candidate capability. The cache holds a weak Node-API reference; its
finalizer removes only its own entry, so a delayed finalizer cannot erase a
replacement. Wrapper collection does not change cleanup identity. If no consumer
retains the old Promise, a later wrapper can obtain the control's already terminal
completion without rerunning Dart cleanup. Teardown invalidates cache owner
pointers before destroying the Owner.

Slot 45 marks a Future with nonempty resource operation leases for final
settlement observation. After output conversion and exit from Dart, the bridge
registers the public Promise with a module-private Node promise hook only when
its actual result is an object/function. The resolver may adopt an arbitrary
thenable. The hook queues an acknowledgement after final settlement; a later
owner-thread pump reenters Dart to release leases. It never attaches a hidden
rejection reaction. Pending capabilities and Dart operations remain strongly
owned until this acknowledgement. Primitive/null results and rejected conversions
release after resolver delivery without installing the hook. Idle observers stop
receiving notifications. A separate finalizable callback sentinel is invalidated
before Owner teardown, so a late acknowledgement cannot dereference a freed
Owner. See [resource semantics and host limits](../doc/resources.md).

Slots 46–48 own, borrow and release a persistent host value. An owner-local map
stores a strong Node-API reference directly for functions, or to a private
holder's own data property for other values. The holder supports every JS value
even on Node-API versions that cannot retain all primitives directly. The
function check uses `napi_typeof`; no payload property, conversion or callback
is read, including for callable Proxies.
Tokens are never reused, and the Dart carrier checks its originating NapiApi
before borrowing a value. Returned handles remain scoped to the current callback.

The carrier attaches a core Dart Finalizer lazily, in Zone.root. Unlike a native
GC callback, this finalizer runs as an ordinary event through the existing Node
owner-thread pump, so it can delete the reference directly. Explicit release
detaches it and is idempotent. Teardown deletes all remaining map entries even
when finalizers were never dispatched, without JS or business cleanup. There is
no additional release queue or global registry. Strong cycles across the two
heaps need an author-directed ownership break; see the
[public ownership contract](../doc/architecture.md#public-contract).
Generated opaque storage and saved callback exceptions use these private operations.

Slots 49–52 open/close a handle scope, invoke a JS function and take/clear a
pending JS exception. Slot 51 accepts either an owned function token or a
borrowed private helper; the owned function is borrowed and invoked inside the
caller's local handle scope. Each invocation's scope covers argument conversion,
execution and result conversion. The generated adapter snapshots all Dart
structural arguments before host validation and owns a caught JS exception before
closing its handles. No callback-scoped handle survives the invocation.

A retained Dart adapter owns its original JS function. A weak Dart cache keyed
by conversion signature and JS identity reuses live adapters without making an
unused adapter permanent. Removing one business registration does not invalidate
other Dart references. Same-owner reentry uses independent invocation scopes;
different-isolate reentry remains rejected.

Slot 53 supplies a private helper: kind 0 maps JS functions to weak identities
and validates binary windows for bulk copies;
kind 1 lazily initializes strict Promise observation and the owner-local incoming
completion queue. Slot 54 obtains the numeric identity inside a C-local handle
scope. Async JS reactions enqueue owned payloads without entering Dart; only the
owning isolate's existing pump invokes `acceptCallback`, in bounded batches of
64. Pending entries retain the adapter until completion. The acceptance closure
returns that root into the current Dart handle scope before discarding its entry,
preventing AOT from removing an otherwise write-only root. A pending Promise
alone does not keep Node alive.

Teardown invalidates the callback sentinel before releasing queue references and
the Dart closure, so late JS reactions cannot access a destroyed owner. It does
not invoke JS or business cleanup. Generated retained and asynchronous callbacks
are tested through fresh packages and workers on Node 24.19.0 and 26.11.1 with
the pinned Dart profile. See the [supported signatures, Promise admission,
lifetime contract and measured costs](../doc/callbacks.md).

Slots 55–56 copy binary input and output in bulk. The input path validates the
actual Uint8Array window, allocates fresh Dart typed data, and copies into its
briefly acquired storage. The output path determines the length before JS
allocation, then reacquires the Dart source only for the copy. Every successful
acquisition is paired with a release; no JS helper, callback or allocation occurs
while the pointer is acquired. ByteBuffer output is normalized to its full byte
view before this handoff. Errors follow the existing pending-exception transport.
These operations neither retain foreign raw pointers nor lock caller buffers.
ABI 15 rebuilds the bridge and bundle metadata using the already compiled VM
runtime; business package builds still use only the ordinary Dart SDK.
