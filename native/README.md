# Native AOT runtime bundle

This guide covers building and distributing the precompiled runtime. Application
authors use the automatic download or local bundle described in
[native builds](../doc/native.md); their business code is compiled as Dart AOT.
All runtime profiles use Dart **3.13.5**, revision
`04bcd1036cdc799ac6564988f159ee454d42c822`, Product mode, uncompressed pointers
and no sanitizers or dynamic modules:

| Profile | Toolchain | Runtime baseline |
| --- | --- | --- |
| macOS arm64 or x64 | Pinned SDK clang/LLD and Xcode SDK | macOS 14 |
| Linux arm64 or x64 | Pinned SDK clang and Debian sysroot | glibc 2.28 |

Other profiles fail explicitly. Node.js has its own host requirements.

## Maintainer build

The bundle builder uses a prepared Product VM object cache, Python 3, and local
Node and libuv headers. macOS also requires Xcode command-line tools.
The builder looks for `uv.h` alongside the Node headers, then in their parent
directory for installations that separate Node and libuv headers. Missing
headers fail explicitly.

On a supported host, prepare the pinned SDK dependencies and VM objects with:

```sh
python3 tool/native/prepare_runtime.py --directory .dart_tool/native-vm
```

The script needs Git and network access on its first run. It fetches only the
runtime source dependencies and build tools, then compiles the VM and dart:io
objects. Reuse that directory for subsequent builds. The SDK checkout is
`.dart_tool/native-vm/sdk`, with its VM cache in `out/ProductARM64` or
`out/ProductX64` on Linux, `xcodebuild/ProductX64` on Intel Macs, or
`xcodebuild/ProductARM64` on Apple Silicon.
Use `--jobs` to limit compilation parallelism. macOS builds use the pinned
SDK clang, LLD and libc++, with the active Xcode SDK.

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

The flat bundle contains `bridge.node`, the identity-qualified runtime (`.dylib`
on macOS or `.so` on Linux), `DART_LICENSE`, `DART_AUTHORS`, `NAPI_LICENSE`, and
`manifest.json`.
The manifest has `format: 1`, `sdkVersion`, `sdkRevision`, `platform: "macos"`,
`architecture: "arm64"`, `minimumOsVersion: "14.0"`, `abi: 15`, `identity`,
`bridge`, `runtime`, and `files` mapping the five payload names to SHA-256 hashes.
Its `build` metadata records the cache arguments hash, combined input-object
digest/count, and runtime/ABI source hash. It contains no local SDK paths.
Linux profiles instead use `platform: "linux"`, `architecture: "arm64"` or
`"x64"`, `libc: "glibc"` and `minimumLibcVersion: "2.28"`, with no
`minimumOsVersion`.
The consumer build validates this manifest and hashes before copying its exact
file whitelist. File hashes validate the distributed assets; runtime identity is described below.

The builder also writes `build.provenance`: the producer commit and
explicit dirty-source flag, hashes of the repository's actual build inputs,
compiler identity and macOS SDK version or Linux toolchain package hashes,
cache recipe hashes, and headers discovered with the compilation flags
(including pinned system headers on Linux) before compiling and checked
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

The Dart 3.13.5 ABI 15 runtime ZIPs and matching locks are available in the
[macOS arm64 release](https://github.com/medz/napi/releases/tag/runtime-dart-3.13.5-abi15),
[macOS x64 release](https://github.com/medz/napi/releases/tag/runtime-dart-3.13.5-macos-x64-abi15),
[Linux x64 release](https://github.com/medz/napi/releases/tag/runtime-dart-3.13.5-linux-x64-abi15),
and [Linux arm64 release](https://github.com/medz/napi/releases/tag/runtime-dart-3.13.5-linux-arm64-abi15).
Set `--url` when packing a new release to record its fixed asset URL.
A lock with a `null` URL requires
`--archive` on an empty cache; a verified cache hit can still be reused.

Application builds on macOS and Linux arm64/x64 use a Dart downloader with the
archive size/hash and manifest hash pinned for each platform, followed by the
same payload validator. They do not invoke this Python tool or require a source
checkout. Archive extraction uses system `ditto` on macOS and `unzip` on Linux.
See [native builds](../doc/native.md) for caching and the explicit local-bundle
override.

Bridge or runtime builds reuse Product VM objects through `build.py`. A change
to the complete source fingerprint does not itself change the ABI or require
recompiling VM objects.

The stable runtime identity includes the pinned SDK revision, mode, architecture,
ABI and a combined digest of the runtime/bridge ABI source hash and VM input
objects digest. New macOS builds also include the compiler, libc++ and Xcode SDK
version. On Linux it also includes the compiler, linker, runtime headers,
linked toolchain files and compilation/link arguments. Distinct VM caches cannot silently share
an identity merely because their Git HEAD matches. The runtime filename/install-name contain
it. The bridge compares the actual linked `NapiDart_RuntimeIdentity()` result
with its compiled expected identity before any VM initialization. Compatible
copies may share one loaded image; an unused local copy is not inspected.
Different actual identities fail. Pack/manifest validation owns asset integrity.
On macOS both native images use deployment target 14.0 and the bridge resolves
its runtime dependency through `@loader_path`. On Linux the bridge links to the
identity-qualified runtime SONAME through `$ORIGIN`. The builder rejects ELF
files with a newer glibc requirement or unexpected dynamic dependencies.

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
