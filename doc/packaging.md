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

These are single-target build and assembly APIs. Shared cross-backend selection/fallback,
runtime supply automation and other native platforms remain #134/#144;
rebuild/replacement behavior remains #135.
