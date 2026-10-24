# Build and publish an npm package

Declare a `PackageBuild` in your own Dart script. Run that script to compile the
selected library and assemble its npm package. The
[quick start](../README.md#build-a-package) has a complete example.

## Declare and run a build

Save this as any Dart file, such as `scripts/package.dart`:

```dart
import 'dart:io';
import 'package:napi/build.dart';

final package = PackageBuild(
  library: File('lib/counter.dart').absolute.uri,
  output: Directory('npm-package'),
  name: '@scope/counter',
  version: '1.0.0',
  metadata: {'description': 'A counter implemented in Dart', 'license': 'MIT'},
  assets: {'LICENSE': File('LICENSE')},
  packagesPath: File('.dart_tool/package_config.json').absolute.path,
);

Future<void> main(List<String> args) => package.run(args);
```

Run it from the Dart project directory:

```sh
dart run scripts/package.dart
dart run scripts/package.dart --help
dart run scripts/package.dart --target native --output npm-native
dart run scripts/package.dart --target wasm --output npm-wasm
dart run scripts/package.dart --target both --output npm-dual
```

`--target native` and `--target wasm` build only that backend. `--target both`
includes both and retains the declaration's `target` as the package root, which
defaults to `BuildTarget.wasm`. Command-line options apply only to that run;
the declaration is unchanged. Selecting Wasm alone does not access a configured
native runtime.

Relative paths, including `--output`, use the working directory. You can use
ordinary Dart expressions to resolve paths differently. `name` and `version`
are required constructor arguments; `metadata` supplies additional npm fields
and must not repeat them. Other options match `buildPackage`, including external
selections and an [offline native runtime](native.md#runtime-download-and-offline-builds).

`run(args)` prints diagnostics and sets a nonzero process exit code on expected
failures, without terminating your script. To compose builds or handle errors
yourself, call `await package.build()` instead. The declaration can also be
imported by another Dart script.

## Rebuild while editing

Pass `--watch` to your build script:

```sh
dart run scripts/package.dart --watch --target wasm
```

The first build runs immediately. Changes to imported or exported Dart sources,
parts, package resolution, and declared assets trigger another build. This
includes local path dependencies. Saves are combined while a build is running;
builds do not overlap. A failed edit prints its diagnostic and leaves the last
usable package in place. Fix the source to rebuild it.

Restart the build script after changing its declaration or other script logic.
Restart consuming Node applications to load new modules; watch mode does not
replace objects in an already loaded Dart runtime. Ctrl+C stops watching and
waits for the active build to finish cleanup.

On Windows, the package path can briefly be unavailable during replacement.
Wait for the successful build message before loading the updated package.

## Call the build API directly

Existing build scripts can continue using `buildPackage`:

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
Wasm is the selected root backend.

## Use Wasm in a browser

Build with `--target wasm`, serve the generated directory over HTTP or HTTPS,
and import `browser.mjs`:

```html
<script type="module">
  import {Counter} from './npm-package/browser.mjs';

  const counter = new Counter(1);
  console.log(counter.increment()); // 2
</script>
```

The import loads and initializes the Wasm automatically. No bundler or Node.js
runtime is required. Keep the generated files together: the loader fetches its
Wasm relative to `browser.mjs`. The npm subpath `@scope/counter/browser` selects
the same entry when your tooling resolves package exports. Dual-backend packages
place these browser files under `wasm/`.

The browser entry includes TypeScript declarations and uses the same functions,
constructors, defaults and conversions as the Node Wasm entry. It is tested with
Chrome 155.0.8059.85; other browsers have not yet been verified. Cancellation uses
`AbortSignal.any()`.

Resource class policies and `JsArray` handles require the Node entrypoint;
browser calls that use them throw `TypeError`. Other exports in the same package
remain usable. Ordinary Dart `List` and `Map` conversions and `JsMap` handles are
supported. Browser declarations retain the shared API, including these Node-only
features.

## Package metadata and files

`metadata` accepts npm fields such as `author`, `contributors`, `repository` and
`license`. `PackageBuild` takes `name` and `version` as separate arguments;
direct `buildPackage` calls include them in `metadata`. Unscoped Node built-in
names such as `path` are rejected; use a scoped name such as `@scope/path` instead.

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
runtime. Native builds support arm64 and x64 on macOS 14 or later and Linux with
glibc 2.28 or later. All supported hosts obtain their runtime automatically. See
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
between them. A broken native entry does not fall back to Wasm.

Native entries also support CommonJS on the supported Node versions (24.19 or
26.11 and later in those major releases):

```js
const {Counter} = require('@scope/counter/native');
const counter = new Counter();
```

For a native-root package, `require('@scope/counter')` selects the native entry.

`require()` and ESM imports share constructors and Dart state, regardless of
which loads first. TypeScript CommonJS files can use
`import bindings = require('@scope/counter/native')` with `module: "NodeNext"`.
Wasm entries continue to require ESM imports.

Both targets must expose the same declarations, conversions, defaults and
cleanup methods. Conditional imports can change private implementations, but a
mismatched public API fails the build. Building both targets requires a
supported native host: macOS or Linux with glibc 2.28 or later, on arm64 or x64.
Including both backends increases package size. Runtime downloads
happen during the author's build, not during npm installation.


## Use Wasm on unsupported native platforms

Set `wasmFallback: true` when building both backends with a native root:

```dart
final package = PackageBuild(
  library: File('lib/counter.dart').absolute.uri,
  output: Directory('npm-package'),
  name: '@scope/counter',
  version: '1.0.0',
  target: BuildTarget.native,
  targets: {BuildTarget.native, BuildTarget.wasm},
  wasmFallback: true,
);
```

Consumers continue using an ordinary ESM import, with automatic initialization:

```js
import {Counter} from '@scope/counter';
const counter = new Counter();
```

The root uses native when the package includes the host's OS and architecture
and its minimum OS/libc requirements are met. Otherwise it selects Wasm.
The Node runtime must support the generated Wasm. A missing optional dependency,
missing artifact or native initialization error on a supported platform still
throws the original native loading error.

This policy applies only to the root **ESM import**. `require('@scope/counter')`
and `/native` always use native and report unsupported platforms. `/wasm` always
uses Wasm. The root shares constructors and Dart state with its selected backend;
the other backend has independent state, and its objects cannot be passed to the
selected backend.

`buildPackage`, `assemblePackage`, `assemblePackageSet` and `PackageRelease`
accept the same `wasmFallback` option. Assembly requires a Wasm module alongside
the native modules. The default remains a fixed root. A build script's `--target native`
or `--target wasm` override builds that single backend and disables fallback
for that invocation.

## Include multiple native platforms

`buildPackage` builds native code for its current host. To publish one package
for several native platforms, run `buildLibrary` on each target host: macOS arm64,
macOS x64, Linux arm64 or Linux x64, with `target: BuildTarget.native`. Transfer
the complete output directories, including their `.napi-output.json` records, to the machine
assembling the npm package:

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

### Download only the installed platform

Use `assemblePackageSet` with the same `modules` to distribute native payloads
as optional npm dependencies:

```dart
final packages = await assemblePackageSet(
  modules: modules,
  output: Directory('release/1.0.0'),
  metadata: {'name': '@scope/counter', 'version': '1.0.0'},
);
```

The output contains an entry package in `package/` and a package for each
native platform, such as `macos-arm64/` and `linux-x64-glibc/`. Native package
names append the platform suffix (`@scope/counter-macos-arm64`) and use the same
version as the entry package. npm selects the compatible dependency using
`os`, `cpu` and `libc`; other runtimes are not downloaded. Consumers continue
to import or require `@scope/counter`.

Publish the native packages first, then the entry package. The returned
directories are in that order. The entry package pins their exact versions.
Keep optional dependencies enabled when installing; missing packages and
native loading failures produce errors. No install script downloads code.
If included, Wasm stays in the entry package. Select it explicitly, or enable
`wasmFallback` for root ESM imports on unsupported native platforms.

Prepare each set in a new output directory. An existing directory is never
replaced, and a failed assembly leaves no partial set. Generated dependency
names cannot also appear in author-supplied dependency fields. Package
descriptions, licensing, registry settings and platform constraints accompany
the native packages; author scripts and dependencies stay in the entry package.
For a single tarball containing all platforms, continue using `assemblePackage`.

### Prepare and publish a release

`PackageRelease` assembles existing modules and packs the resulting npm packages
before uploading anything. Use it from your own Dart script:

```dart
final release = PackageRelease(
  modules: modules,
  output: Directory('release/1.0.0'),
  name: '@scope/counter',
  version: '1.0.0',
  metadata: {'publishConfig': {'access': 'public'}},
);
await release.run(args);
```

For example, if the script is named `tool/release.dart`:

```sh
dart run tool/release.dart prepare
# Inspect release/1.0.0/packages and release/1.0.0/tarballs.
dart run tool/release.dart publish
```

Preparation needs no registry credentials. It does not compile missing targets
or replace an existing preparation. Native payloads become separate packages;
a Wasm-only release uses one package and `target: BuildTarget.wasm`.

Publishing uses the prepared tarballs, checks existing versions by integrity,
and uploads native packages before the entry package. A conflicting version
stops publication. If an upload fails, the diagnostic lists confirmed and
pending packages. Retry `publish` with the same output: identical published
versions are skipped, with their existing distribution tags unchanged.

npm handles authentication, scoped registries and trusted publishing. Use
`publishConfig` or pass `--registry`, `--tag` and `--access` to `publish`.
Registry overrides apply to both verification and upload. Programmatic callers
can use `release.prepare()` and `release.publish(...)` directly. Keep the
prepared output intact until publishing finishes; do not edit its metadata or
tarballs between attempts.

## Managed rebuilds

Call `buildPackage`, `buildLibrary` or a single-package assembly API again with the same output
directory. Rebuilds support local macOS APFS, supported 64-bit Linux ext-family
filesystems or tmpfs, and Windows NTFS.

macOS and Linux replace the directory atomically. Windows moves the previous
result to a private backup before publishing the new directory, so the output
may be briefly unavailable. A file or directory held open without delete sharing
can prevent replacement; the build reports the error and restores the previous
result. The output stays a normal directory that can be moved on its own.

Generated files are replaced and obsolete artifacts are removed. Other author
files and metadata are retained, including permissions, ownership, ACLs and
file attributes. POSIX extended attributes are preserved on macOS and Linux.
Unchanged files retain their timestamps. Explicit metadata
replaces whole top-level fields; nested objects are not merged. Omitted selected
documentation assets are retained, while supplying an asset again replaces it.

Do not edit generated files or the builder's `.napi-output.json` ownership record.
Edited artifacts, conflicting author files, missing ownership records, symlinks
and special files cause the rebuild to fail before replacement. Keep
`.napi-locks` intact and do not edit the output while a build is running.

Compilation or merge failures leave the previous package in place. A cleanup
failure after successful replacement reports the retained temporary path;
the new package is still usable. On Windows, the next build recovers interrupted
replacement from `.napi-locks` when the recorded output still matches. Changed
output or backup content is retained and reported instead of overwritten.
This recovery handles process interruption; it does not guarantee persistence
after a power failure.

Raw modules built by `buildLibrary` have their own ownership record. They can
be rebuilt, but cannot replace an npm package directory or adopt older raw output
without an ownership record. Package assembly copies only runtime artifacts;
the raw module's record stays outside the npm package.

Linux requires `statx` and extended-attribute support, and the builder must have
permission to preserve retained metadata. Windows requires permission to retain
file security and rejects path segments ending in a dot or space. Use full output
directory names: existing DOS short names are resolved, but an absent short name
cannot be used while a replacement is in progress. Rebuilding on network or other
unsupported filesystems, and adopting legacy output are not supported.
Use a fresh output directory in those cases.
