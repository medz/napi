# Build and publish an npm package

Use `buildPackage` in a Dart build script to compile a library and assemble its
npm package. The [quick start](../README.md#build-a-package) has a complete example.

```dart
await buildPackage(
  library: File('lib/counter.dart').absolute.uri,
  packagesPath: File('.dart_tool/package_config.json').absolute.path,
  output: Directory('npm-package'),
  metadata: {
    'name': '@scope/counter',
    'version': '1.0.0',
    'description': 'A counter implemented in Dart',
    'license': 'MIT',
  },
  assets: {'LICENSE': File('LICENSE')},
);
```

## Install or publish

Install the built directory in a local Node project:

```sh
npm install /path/to/npm-package
```

To move it to another project or inspect what will ship, create a tarball:

```sh
npm pack ./npm-package
```

Publish from the generated directory when it is ready:

```sh
cd npm-package
npm publish --access public
```

Keep the complete generated package and its license notices. Consumers import
from the package root; they do not initialize the runtime manually. `/module.wasm`
selects the Wasm entry. It shares the root's constructors and state only when
Wasm is the root target.

## Package metadata and files

`metadata` accepts npm fields such as `name`, `version`, `author`, `contributors`,
`repository` and `license`. Unscoped Node built-in names such as `path` are
rejected; use a scoped name such as `@scope/path` instead.

The builder manages entrypoints and generated files. Supplying `type`, `files`,
`exports`, `imports`, `main`, `module`, `types`, `typings`, `browser` or `bin` is an
error.

`assets` can include a README, LICENSE, NOTICE or CHANGELOG at the package root.
Supported filenames are `README` or `README.md`; `LICENSE` and `NOTICE` with no
extension, `.md` or `.txt`; and `CHANGELOG.md`. Other paths, executable files and
symlinks are rejected.

Use `buildLibrary` for raw artifacts. `assembleWasmPackage` and
`assembleNativePackage` package an existing `BuiltModule` without compiling it
again. `assemblePackage` combines modules built on separate hosts.

## Choose native or Wasm

Wasm is the default. Native and Wasm packages can be built and published
independently:

```dart
await buildPackage(
  library: File('lib/counter.dart').absolute.uri,
  output: Directory('npm-native'),
  metadata: {'name': '@scope/counter-native', 'version': '1.0.0'},
  target: BuildTarget.native,
);

await buildPackage(
  library: File('lib/counter.dart').absolute.uri,
  output: Directory('npm-wasm'),
  metadata: {'name': '@scope/counter-wasm', 'version': '1.0.0'},
  target: BuildTarget.wasm,
);
```

Each output is a complete npm package: use `npm pack ./npm-native` or
`npm pack ./npm-wasm`, and publish from the corresponding directory. The native
package contains only native artifacts; the Wasm package needs no native
runtime. Native builds support macOS 14 or later on arm64 and Linux x64 with
glibc 2.28 or later. Both platforms obtain their runtime automatically. See
[native builds](native.md).

To ship both backends in one package:

```dart
await buildPackage(
  library: File('lib/counter.dart').absolute.uri,
  output: Directory('npm-package'),
  metadata: {'name': '@scope/counter', 'version': '1.0.0'},
  targets: {BuildTarget.wasm, BuildTarget.native},
  target: BuildTarget.wasm,
);
```

`target` chooses the package root. Consumers can also choose explicitly:

```js
import {Counter} from '@scope/counter';        // Wasm, as chosen above
import {Counter as NativeCounter} from '@scope/counter/native';
import {Counter as WasmCounter} from '@scope/counter/wasm';
```

The root and its selected subpath share the same constructors and state. The
other backend has separate Dart state; objects and resources cannot cross
between them. A broken native entry does not fall back to Wasm. CommonJS is not
supported.

Both targets must expose the same declarations, conversions, defaults and
cleanup methods. Conditional imports can change private implementations, but a
mismatched public API fails the build. Building both targets requires a
supported native host: macOS arm64, or Linux x64 with glibc 2.28 or later.
Including both backends increases package size. Runtime downloads
happen during the author's build, not during npm installation.

## Include multiple native platforms

`buildPackage` builds native code for its current host. To publish one package
for both native platforms, run `buildLibrary` on macOS arm64 and Linux x64, each
with `target: BuildTarget.native`. Transfer the complete output directories,
including their `.napi-output.json` records, to the machine assembling the npm
package:

```dart
await assemblePackage(
  modules: [
    BuiltModule(
      Directory('artifacts/macos'),
      '3.13.5',
      target: BuildTarget.native,
    ),
    BuiltModule(
      Directory('artifacts/linux'),
      '3.13.5',
      target: BuildTarget.native,
    ),
  ],
  target: BuildTarget.native,
  output: Directory('npm-package'),
  metadata: {'name': '@scope/counter', 'version': '1.0.0'},
);
```

Assembly copies existing artifacts and can run on a different host from either
build. The modules must have matching public APIs and use the same supported
Dart SDK. Consumers import from the package root; it selects the matching
native artifact for their OS, architecture and libc. Unsupported platforms,
missing artifacts and native loading failures produce an error.

All included platforms ship in the same tarball, increasing its download size.
There are no platform-specific npm dependencies or install scripts. Add a Wasm
`BuiltModule` to `modules` to expose `/wasm` alongside `/native`; `target` still
chooses the root backend, and native loading failures never switch to Wasm.

## Managed rebuilds

Call `buildPackage`, `buildLibrary` or the assembly API again with the same output
directory. The builder replaces its own managed output atomically on local macOS
APFS and supported 64-bit Linux ext-family filesystems or tmpfs.

Generated files are replaced and obsolete artifacts are removed. Other author
files and metadata are retained, including permissions, ownership, ACLs and
extended attributes. Unchanged files retain their timestamps. Explicit metadata
replaces whole top-level fields; nested objects are not merged. Omitted selected
documentation assets are retained, while supplying an asset again replaces it.

Do not edit generated files or the builder's `.napi-output.json` ownership record.
Edited artifacts, conflicting author files, missing ownership records, symlinks
and special files cause the rebuild to fail before replacement. Keep
`.napi-locks` intact and do not edit the output while a build is running.

Compilation or merge failures leave the previous package in place. A cleanup
failure after successful replacement reports the retained temporary path;
the new package is still usable.

Raw modules built by `buildLibrary` have their own ownership record. They can
be rebuilt, but cannot replace an npm package directory or adopt older raw output
without an ownership record. Package assembly copies only runtime artifacts;
the raw module's record stays outside the npm package.

Linux requires `statx` and extended-attribute support, and the builder must have
permission to preserve retained metadata. Rebuilding on Windows, network or
other unsupported filesystems, and adopting legacy output are not supported.
Use a fresh output directory in those cases.
