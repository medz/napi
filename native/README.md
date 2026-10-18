# Native AOT runtime bundle

This guide covers building and distributing the precompiled runtime. Application
authors use the automatic download or local bundle described in
[native builds](../doc/native.md); their business code is compiled as Dart AOT.
The current profile is Dart **3.13.5**, revision
`04bcd1036cdc799ac6564988f159ee454d42c822`, **macOS arm64 Product**, uncompressed
pointers, no sanitizers/dynamic modules, and deployment target **14.0**.
Other profiles fail explicitly.

## Maintainer build

Prerequisites are an existing checkout of that exact SDK with its dependencies,
a prepared Product VM build cache, Xcode command-line tools, Python 3, and local
Node and libuv headers. The build tool requires these inputs to be prepared
before it runs.
The builder looks for `uv.h` alongside the Node headers, then in their parent
directory for installations that separate Node and libuv headers. Missing
headers fail explicitly. The current macOS profile uses system Apple clang.

To prepare a cache, copy `native/runtime/` into the SDK as `runtime/napi/` in a
checkout where that directory does not already exist. Do not overwrite an
unrelated SDK customization. The included `BUILD.gn` follows the pinned SDK's
`runtime/engine/BUILD.gn` and provides the `napi_runtime` cache-preparation target.
Generate the Product cache with GN and Ninja:

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
Its `build` metadata records the cache arguments hash, combined input-object
digest/count, and runtime/ABI source hash. It contains no local SDK paths.
The consumer build validates this manifest and hashes before copying its exact
file whitelist. File hashes validate the distributed assets; runtime identity is described below.

The builder also writes `build.provenance`: the producer commit and
explicit dirty-source flag, hashes of the repository's actual build inputs,
compiler identity and macOS SDK version, cache recipe hashes, and non-system
headers discovered with the compilation flags before compiling and checked
again against the actual compiler dependency files. Source, VM objects, cache
recipes and compiler hashes are also checked again before publication; detected
input drift fails the build. Keep the prepared cache and toolchain unchanged
while building. This detects accidental concurrent changes, not an adversarial
writer that changes and restores files between checks.
Provenance describes the inputs captured during that build. A dirty producer is
identified by its complete input hashes; its commit alone cannot reproduce those
bytes. The existing `build.sourceSha256` remains the narrower
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
Pass `--url` with a fixed GitHub release asset URL, or omit it to leave the URL
`null`. Preparing a lock does not upload the archive.
If the archive is published but a concurrent writer prevents lock publication,
the command fails and preserves the archive path; it does not delete a file that
another process may already have replaced. Inspect the reported paths and use
new output names when retrying.

To validate and cache a local archive:

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

The [Dart 3.13.5 ABI 15 release](https://github.com/medz/napi/releases/tag/runtime-dart-3.13.5-abi15)
contains the macOS arm64 ZIP and its matching lock. Set `--url` when packing a
new release to record its fixed asset URL. A lock with a `null` URL requires
`--archive` on an empty cache; a verified cache hit can still be reused.

Application builds use a Dart downloader with the archive size/hash and manifest
hash pinned in the package, followed by the same payload validator. They do not
invoke this Python tool or require a source checkout. See [native builds](../doc/native.md)
for caching and the explicit local-bundle override.

Bridge or runtime builds reuse Product VM objects through `build.py`. A change
to the complete source fingerprint does not itself change the ABI or require
recompiling VM objects.

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

[`runtime/runtime.h`](runtime/runtime.h) declares the runtime entrypoints for
identity, VM initialization, immutable AOT snapshots, isolate entry/exit,
microtasks, errors and isolate shutdown. Public Dart C APIs provide scopes,
values, invocation and persistent handles while an isolate is entered.

[`bridge/abi.h`](bridge/abi.h) defines the compiler-private ABI 15 table with
57 slots. Generated Dart bindings validate its size before reading it. The table
covers declaration registration, presence, reference wrappers, structural
conversion, Futures, resources, owned host values, callbacks and binary copies.
It is an internal interface between the matching compiler and runtime bundle.

Each Node environment owns its isolates, handle scopes and persistent
references. Weak wrapper caches preserve live identity without rooting wrappers.
Replacing a collected wrapper creates a new lease; its predecessor's delayed
finalizer can release only the old lease. Borrowed JS handles last only for the
current callback scope. Values retained beyond it use owned references.

The owner thread runs Dart work through one libuv async handle per isolate.
Notifications increment an atomic count, so coalesced wakeups cannot lose
messages. A turn processes at most 64 notifications and drains microtasks
between Dart messages. JS Promise reactions enqueue results without entering
Dart; the owner pump delivers them after the active call has exited.

A scheduled drain keeps Node alive until it runs. Live Dart ports or remaining
notifications keep the handle referenced; an unresolved Future alone does not.
Uncaught Dart errors use `napi_fatal_exception`. Different-isolate reentry while
Dart is active is rejected.

An async environment cleanup hook invalidates wrappers and callback sentinels,
releases persistent handles and shuts down only its own isolate. Shutdown stops
notifications before `uv_close`; queued wakeups retain the owner until the close
callback completes. Runtime images remain resident with `RTLD_NODELETE` because
there is no process-global VM shutdown. This supports Worker unload/reload.

Futures retain arguments and receivers through conversion and resolver delivery.
Resource operations with object results retain their leases through public
Promise settlement, including thenable adoption. Retained Dart callbacks own
their JS function; weak adapter caches reuse live adapters. Teardown discards
pending capabilities without invoking JS or business cleanup. See
[Future semantics](../doc/futures.md), [resources](../doc/resources.md) and
[callbacks](../doc/callbacks.md).

Persistent host values support every JS value, including null, undefined,
symbols and functions. A Dart finalizer releases unreachable acyclic carriers
on the owner thread. Cross-heap cycles require an explicit ownership break; see
[opaque ownership](../doc/opaque.md#ownership).

Bulk binary operations validate the current view, allocate the destination and
copy within a short acquired-pointer interval. No JS callback or allocation runs
while a Dart pointer is acquired, and every successful acquisition is released.
No foreign raw pointer survives the call. See [binary snapshots](../doc/binary.md)
and [shared byte views](../doc/shared-bytes.md).

The embedding implementation depends on private Dart SDK initialization,
core-library setup and microtask APIs. Dart-created child isolates,
interruption of non-returning Dart code and cross-identity VM sharing are
unsupported. `DART_LICENSE` and `DART_AUTHORS` retain upstream attribution;
original bridge code uses the package license.
