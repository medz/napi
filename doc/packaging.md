# Fresh npm packages

`buildPackage` from `package:napi/build.dart` validates npm metadata before source
analysis or compilation, then builds and assembles a fresh package. It removes
its temporary build files and never replaces existing output. The default Wasm
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
The rejection table covers the 42 legal bare-name collisions on Node 24.19.0 and
26.11.1. Tests compare it with each tested runtime's actual `builtinModules` and
`isBuiltin` inventory. Prefix-only names such as `test`, `sqlite`, `sea` and `ffi`
remain valid. A collision reports the offending name and suggests `@scope/name`.
See Node's [built-in module rules](https://nodejs.org/api/modules.html#built-in-modules-with-mandatory-node-prefix).

Use `target: BuildTarget.native` with `nativeRuntime` for a native package. The
same early metadata validation applies to both targets. `buildLibrary` remains
available for raw artifacts; `assembleWasmPackage` and `assembleNativePackage`
assemble an existing `BuiltModule` without recompiling. Those lower-level
assembly calls validate metadata at assembly time, so use `buildPackage` when
the npm name is known before compilation.

The runtime file allowlist is `module.wasm`, `module.d.wasm.ts`, `host.mjs`,
`boundary.mjs`, and `DART_LICENSE`, plus `core.wasm`, `calls.mjs` and
`references.mjs` together when present. `DART_LICENSE` is required. Other
build-directory files are ignored.
Explicit assets may use `README`, `README.md`, `LICENSE`, `LICENSE.md`,
`LICENSE.txt`, `NOTICE`, `NOTICE.md`, `NOTICE.txt`, and `CHANGELOG.md`. Asset
destinations are flat names; arbitrary paths, executable assets, symlinks,
traversal, and NUL paths are rejected. Symlink components are also rejected;
resolve an intentional system path alias before calling this API.

Assembly validates inputs before creating staging, copies the allowlist into a
sibling staging directory, and calls the existing atomic no-replace publisher.
Existing files, directories, and links remain untouched. Concurrent mutation of
source inputs is unsupported; this is not an open-file-descriptor sandbox.

`dart run tool/package_assembly_fixture.dart` builds real Dart Wasm, packs the npm
package, moves its tarball to a path with spaces, removes the build/package
directories, and installs a fresh consumer. Node imports and TypeScript
NodeNext/Bundler resolution exercise both package entrypoints, argument defaults,
UTF-16 strings, and invalid argument rejection. The compiler remains pinned to
Dart 3.13.5 and its experimental Wasm integration; use the repository's tested
Node and TypeScript versions from CI.

`assembleNativePackage` uses the same metadata, assets and atomic publication
rules for a `BuildTarget.native` module. Its root and `./native` exports load
`module.mjs` with `module.d.mts` declarations. It copies business AOT and only the
manifest-declared bridge/runtime/license files, validating their hashes again
after copying. The initial native package is macOS arm64; conflicting `os` or
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
  nativeRuntime: Directory('runtime-bundle'),
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
automatic platform selection are outside this slice.

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

Dual packages require the existing pinned macOS arm64 native runtime bundle and
standard Dart SDK. They compile business code for each target sequentially,
include both complete asset/license sets, and publish only after both succeed.
The root does not receive native-only `os`/`cpu` metadata, so it can be installed
for Wasm use on another supported host. Caller-provided host restrictions are
retained. Including both targets increases download size; there is no optional
platform package or install-time download.

`dart run tool/dual_target_fixture.dart <native-runtime-bundle>` checks source
and external builds, both root choices, fresh relocated npm installs, explicit
subpaths, repeated imports, separate runtime identities, failed assets, Workers,
resource/Future/Stream use and strict TypeScript. `NAPI_NODE_EXECUTABLES` runs the
same installed artifacts with each configured Node runtime. A native AOT failure
after a successful Wasm build verifies that no partial package is published and
unrelated author files survive.

Fresh assembly continues to reject existing output and uses atomic no-replace
publication. Author-owned output merging and atomic rebuild/replacement remain
#135. Automatic backend selection, runtime supply and other native platforms
remain #134/#144; this explicit dual-target slice does not complete those issues.
