# npm packages

`buildPackage` from `package:napi/build.dart` validates npm metadata before source
analysis or compilation, then builds and assembles a package. New output uses
atomic no-replace publication. A package created by this builder can also be
rebuilt on local macOS APFS and supported 64-bit Linux filesystems; see the managed
rebuild rules below. The default Wasm
target exports `module.wasm` from both the package root and `./module.wasm`, with
the same generated TypeScript declarations.

```dart
final package = await buildPackage(
  library: File('lib/math.dart').absolute.uri,
  packagesPath: File('.dart_tool/package_config.json').absolute.path,
  output: Directory('npm-package'),
  metadata: {
    'name': '@scope/path',
    'version': '1.0.0',
    'author': {'name': 'Package Author'},
    'license': 'MIT',
  },
  assets: {'LICENSE': File('LICENSE')},
);
```

Caller-owned JSON metadata, including `author`, `contributors`, `repository`,
and `license`, is retained. Builder-owned `type`, `files`, `exports`, `imports`,
`main`, `module`, `types`, `typings`, `browser`, and `bin` fields cause an explicit
conflict error when supplied. Scoped names such as `@scope/path` are valid;
unscoped Node built-in names are rejected without requiring Node to be installed.
The rejection table covers bare-name collisions on Node 24.19.0 and 26.11.1.
Prefix-only names such as `test`, `sqlite`, `sea` and `ffi`
remain valid. A collision reports the offending name and suggests `@scope/name`.
See Node's [built-in module rules](https://nodejs.org/api/modules.html#built-in-modules-with-mandatory-node-prefix).

Use `target: BuildTarget.native` for a native package. The matching runtime is
downloaded and cached; `nativeRuntime` can select a local bundle for offline
builds. The same early metadata validation applies to both targets. `buildLibrary` remains
available for raw artifacts; `assembleWasmPackage` and `assembleNativePackage`
assemble an existing `BuiltModule` without recompiling. Those lower-level
assembly calls validate metadata at assembly time, so use `buildPackage` when
the npm name is known before compilation.

The Wasm runtime file allowlist is `module.wasm`, `module.d.wasm.ts`, `host.mjs`,
`boundary.mjs`, and `DART_LICENSE`, plus `core.wasm`, `calls.mjs` and
`references.mjs` together when present. `DART_LICENSE` is required. Other
build-directory files are ignored.
Explicit assets may use `README`, `README.md`, `LICENSE`, `LICENSE.md`,
`LICENSE.txt`, `NOTICE`, `NOTICE.md`, `NOTICE.txt`, and `CHANGELOG.md`. Asset
destinations are flat names; arbitrary paths, executable assets, symlinks,
traversal, and NUL paths are rejected. Symlink components are also rejected;
resolve an intentional system path alias before calling this API.

Assembly validates inputs before creating staging, copies the allowlist into a
sibling staging directory, and publishes the completed result. Existing files,
links and unmanaged directories remain untouched. Inputs and output cannot
contain one another; external package URIs use the frontend's resolved source
path for this check. Concurrent mutation of source inputs is unsupported; this
is not an open-file-descriptor sandbox.

## Managed rebuilds

Call the same build or assembly API with the same output path. The builder's
private `.napi-output.json` records the known artifact layout, hashes, selected
documentation assets and ownership of native platform fields. It is omitted
from the npm `files` list and tarball. An older output without this marker is
unmanaged and is rejected; filename similarity does not confer ownership.

Before publication, rebuilds verify the old generated files and fields. Edited
generated artifacts, edited exports/file lists and collisions with newly
generated paths fail without replacing the old package. Stale generated files
are removed. Other author files and directories are copied independently, and
author JSON fields are retained. Explicit metadata replaces a field at its top
level, including an explicit `null`; nested objects are not recursively merged.
Omitting a previously selected documentation asset retains its current content
and its selection in `files`. Supplying the asset again replaces it. Unrelated
author files do not expand the generated `files` list.

Native-only `os`/`cpu` defaults are removed when switching to Wasm or dual output.
Restrictions explicitly supplied by the author remain. A subsequent native-only
build still requires the native platform values. Keep the private ownership
record intact; it is build bookkeeping, not author configuration.

Rebuilders hold a fail-fast lock at `<parent>/.napi-locks/<output basename>` using
`flock`. Keeping the original basename lets the filesystem handle case and
Unicode-equivalent spellings without increasing filename length. Separate
processes and Dart isolates contend on the same inode. The private directory and
lock files remain after release or process exit: deleting them while another
builder runs would split the lock. Output paths inside `.napi-locks`, or a
symlink/non-directory at that private path, are rejected without replacing it.
Fresh POSIX package builds also use this lock; raw module publication uses an exclusive rename without this lock.

The new package is committed with one directory exchange:
`renamex_np(RENAME_SWAP)` on macOS or `renameat2(RENAME_EXCHANGE)` on Linux.
Compilation or merge failures do not replace the old package. After a successful
exchange, failure to remove old output or build scratch reports the retained path
and still returns success; it never rolls the package back. An exchange error
retains both names for inspection, without attempting two renames. This is atomic
directory-name visibility, not a snapshot across multiple independent file opens
or a power-loss durability guarantee. External programs editing output during a
rebuild are unsupported; a final content/stat check catches changes but cannot
serialize non-cooperating writers.

Copies preserve author file metadata through the pinned macOS Dart SDK's
`File.copy` (`COPYFILE_ALL`), and directory metadata through `copyfile` with
`COPYFILE_METADATA`, including ACLs and extended attributes. On Linux, retained
files and directories restore their ownership, permissions, ACLs and extended
attributes through libc after writes finish. Unchanged author files also retain
their timestamps; the rewritten `package.json` keeps its new modification time.
Validation and copying use normal reads, so a failed rebuild can still advance
access times on the old output.
The builder needs permission to preserve the original ownership and attributes.
Preservation errors
fail before publication. Symlinks and special files anywhere in an existing
package are rejected rather than dropped. Copying and verification cost scales
with the retained contents; an installed `node_modules` tree receives no special
exemption. No hard links are used as snapshots.

Existing-output replacement supports local macOS APFS and 64-bit Linux ext-family
filesystems with directory-exchange support or tmpfs. Linux requires `statx` and
extended-attribute support. Windows, network/other filesystems, legacy package adoption and raw module
replacement are not supported. New-output publication retains its existing
platform support. No extra flags, install scripts or external copy tools are
required.

The compiler remains pinned to Dart 3.13.5 and its experimental Wasm integration;
see [supported toolchains](../README.md#verify).

`assembleNativePackage` uses the same metadata, assets and atomic publication
rules for a `BuildTarget.native` module. Its root and `./native` exports load
`module.mjs` with `module.d.mts` declarations. It copies business AOT and only the
manifest-declared bridge/runtime/license files, validating their hashes again
after copying. The native package currently targets macOS arm64; conflicting `os` or
`cpu` metadata is rejected. See [native setup and scope](native.md).

## Explicit dual-target packages

To include both backends, pass `targets` to `buildPackage`. `target` selects the
package root, and defaults to Wasm:

```dart
await buildPackage(
  library: File('lib/math.dart').absolute.uri,
  output: Directory('npm-package'),
  metadata: {'name': '@scope/math', 'version': '1.0.0'},
  targets: {BuildTarget.wasm, BuildTarget.native},
  target: BuildTarget.wasm,
);
```

The package stores artifacts under `wasm/` and `native/`. Its root resolves
directly to the selected backend, without another loader. `@scope/math/native`
and `@scope/math/wasm` explicitly select a backend;
`@scope/math/module.wasm` is an alias of the Wasm entry. Direct relative Wasm
imports use the physical `wasm/module.wasm` path. Existing single-target packages
retain their flat layout and entrypoints.

Importing the root and its selected subpath shares functions, constructors and
state. Importing the other backend creates a separate Dart runtime and state;
reference objects and resources cannot cross between them. A missing or broken
selected backend fails normally. No failure triggers an implicit fallback, and
importing Wasm does not initialize native. CommonJS, browser initialization and
automatic platform selection are not supported.

Both targets resolve their own Dart conditional imports. Their ordered public
declarations, strict conversion policies, parameter presence, evaluated defaults
and resource cleanup contracts must match. Different private implementation
names and source locations are allowed. Changed declaration order is rejected
explicitly; this build does not reorder selected class IDs or infer equivalence
between different public contracts. Reference-view composition and concrete
alias ambiguity groups must also agree. Defaults compare their effective Dart
values, so omitted nullable defaults equal explicit `null`, while signed zeros
remain distinct.

One emitter produces identical declaration text for both targets. The text is
stored in separate declaration modules so class brands remain specific to each
backend. Root types resolve to the selected module, preserving type identity
with that subpath. A single shared physical declaration module would incorrectly
allow foreign-runtime references. The default/presence and conversion comparison
also catches differences such as `int` versus `double` that both spell `number`
in TypeScript.

Dual packages require macOS arm64 and the standard Dart SDK. The builder obtains
the pinned native runtime automatically, or uses an explicit `nativeRuntime`.
They compile business code for each target sequentially,
include both complete asset/license sets, and publish only after both succeed.
The root does not receive native-only `os`/`cpu` metadata, so it can be installed
for Wasm use on another supported host. Caller-provided host restrictions are
retained. Including both targets increases download size; there is no optional
platform package or install-time download.

Managed rebuilds follow the same rules for single and dual output; legacy output
still cannot be adopted automatically. Automatic backend selection and other native platforms
are not supported.
