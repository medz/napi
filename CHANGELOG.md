## 0.23.0

This release adds typed build scripts with watch mode, browser ESM imports,
and native support for Windows x64, Linux arm64 and Intel Macs. Native payloads
can now be distributed as separate npm packages, with a reusable release script
for preparing and publishing them.

### 🛠️ Build from your own Dart script

Declare a package once and let the script handle build options:

```dart
import 'dart:io';
import 'package:napi/build.dart';

final package = PackageBuild(
  library: File('lib/counter.dart').absolute.uri,
  output: Directory('npm-package'),
  name: '@scope/counter',
  version: '1.0.0',
);

Future<void> main(List<String> args) => package.run(args);
```

The filename is up to you:

```sh
dart run scripts/package.dart --target native
dart run scripts/package.dart --watch --target wasm
```

Watch mode follows imported sources, local dependencies and declared assets. It
serializes builds and retains the last usable output after a compilation error.
Restart the script after changing its build declaration, and restart consuming
applications to load rebuilt modules.

The [starter](https://github.com/medz/napi/releases/download/v0.23.0/napi-starter.zip)
includes a Counter, build script and JavaScript consumer. Existing `buildPackage`
scripts continue to work.

[Build scripts and watch mode](https://github.com/medz/napi/blob/v0.23.0/doc/packaging.md)

### 🌐 Import Wasm in the browser

Serve the generated Wasm package over HTTP and use its browser entry:

```html
<script type="module">
  import {Counter} from './npm-package/browser.mjs';
  const counter = new Counter();
  console.log(counter.increment());
</script>
```

The entry loads and initializes Wasm automatically. Dual-target packages place
it under `wasm/`; npm also exposes the `/browser` subpath. Resource classes and
`JsArray` still require Node.js, and browser calls using them throw `TypeError`.
Browser execution has been verified in Chrome 155; other browsers have not yet
been verified.

Native entries now also support CommonJS:

```js
const {Counter} = require('@scope/counter');
```

When both select native, `require()` and ESM imports share constructors and Dart
state. Wasm entries remain ESM-only.

Dual-target packages can opt into `wasmFallback: true` with a native root. Root
ESM imports then choose Wasm on unsupported native platforms. Missing or damaged
native artifacts on a supported platform remain errors; explicit `/native`
imports and CommonJS stay native-only.

[Browser entries and backend selection](https://github.com/medz/napi/blob/v0.23.0/doc/packaging.md)

### 📦 Distribute native addons across platforms

Precompiled runtimes are now available for Windows x64, Linux arm64 and macOS
x64, alongside the existing macOS arm64 and Linux x64 targets. Application
builds need the ordinary Dart SDK; uncached Linux builds also need
`/usr/bin/unzip`. npm consumers need Node.js and the generated package. Runtime
downloads happen during the author's build.

Build native modules on each target host, then use `assemblePackage` to include
all platforms in one tarball, or `assemblePackageSet` to publish native payloads
as optional dependencies. With a package set, npm installs the matching native
payload and consumers keep one package import.

`PackageRelease` prepares fixed tarballs and publishes native dependencies before
the entry package. Interrupted publication can resume from the same preparation:
matching published versions are skipped, while conflicting bytes stop the release.
Publication is not transactional across multiple packages.

Native builds support macOS 14 or later, Linux with glibc 2.28 or later, and
Windows 10 / Server 2016 or later on x64. Windows runtime execution has been
tested on Server 2025. Node.js has its own OS requirements. Cross-compiling and
musl remain unsupported.

[Native builds](https://github.com/medz/napi/blob/v0.23.0/doc/native.md) ·
[Platform packages and publication](https://github.com/medz/napi/blob/v0.23.0/doc/packaging.md#download-only-the-installed-platform)

### Other improvements

- Windows can rebuild managed modules and npm packages on local NTFS while
  retaining author files. The output path can briefly be unavailable during
  replacement; wait for the successful build message before loading it.
- Wasm binary snapshots use bulk copies to reduce calls across the Dart/JavaScript
  boundary.
- The [performance guide](https://github.com/medz/napi/blob/v0.23.0/doc/performance.md)
  compares native, Wasm and napi-rs package sizes, startup and call overhead,
  including byte-copy and shared-view workloads.

Both backends require Dart 3.13.5. Native runtimes use bridge ABI 15.

[Release on GitHub](https://github.com/medz/napi/releases/tag/v0.23.0)

## 0.22.0

This release brings native Dart addons to Linux x64 with automatic runtime
downloads, and lets generic subclasses carry additional JavaScript payloads.

### 🐧 Build native addons on Linux

Use the same build API on Linux x64 and macOS arm64:

```dart
await buildPackage(
  library: File('lib/counter.dart').absolute.uri,
  output: Directory('npm-package'),
  packagesPath: File('.dart_tool/package_config.json').absolute.path,
  target: BuildTarget.native,
  metadata: {'name': '@scope/counter', 'version': '1.0.0'},
);
```

The first build downloads a precompiled runtime. Application authors need the
ordinary Dart SDK, without a C/C++ toolchain or Dart SDK sources. npm consumers
need only Node.js and the generated package; installation and import do not
perform runtime downloads.

Linux requires x64 and glibc 2.28 or later. `/usr/bin/unzip` is needed only
when downloading and extracting an uncached runtime. Cached runtimes support
offline builds; `NAPI_RUNTIME_CACHE` selects a custom cache, and
`nativeRuntime` still accepts a local bundle. Downloads and cached files are
verified against pinned hashes.

Each native package targets one platform. Automatic platform selection,
cross-compiling and musl distributions such as Alpine remain unsupported.
Both backends require Dart 3.13.5; native runtimes use ABI 15.

[Native builds and offline use](https://github.com/medz/napi/blob/v0.22.0/doc/native.md)

### 🧩 Add payload parameters in subclasses

A subclass can now introduce independent generic parameters:

```dart
@NAPI()
class Box<T> {
  Box(this.value);
  T value;
}

@NAPI()
class Tagged<T, Meta> extends Box<T> {
  Tagged(super.value, this.metadata);
  Meta metadata;
}
```

```js
const metadata = {source: 'cache'};
const box = new Tagged('value', metadata);
box instanceof Box;         // true
box.metadata === metadata;  // true
```

Parent and child views share the same JavaScript object. Generic subclasses can
also inherit selected non-generic classes, including resource classes. Each
ancestor parameter must still map to a distinct, non-nullable child parameter;
fixed, repeated or nested mappings remain unsupported.

[Generic inheritance](https://github.com/medz/napi/blob/v0.22.0/doc/opaque.md#reference-inheritance)

### Other improvements and fixes

- Private constant defaults can contain Dart type values such as `String`,
  `List<int>` and record types. These values stay inside Dart; `Type` is not a
  JavaScript-facing type. Function types and `void` remain unsupported inside
  inaccessible defaults.
- Preserve the canonical identity of constant defaults containing `NaN` on x64.

[Constant defaults](https://github.com/medz/napi/blob/v0.22.0/doc/arguments.md#constant-defaults)

[Release on GitHub](https://github.com/medz/napi/releases/tag/v0.22.0)

## 0.21.0

This release lets native and Wasm bindings use objects with private const
constructors as defaults, including defaults in value-class input properties.

### 📦 Keep private Dart defaults

You no longer need to expose a public constructor or constant solely to make
these defaults available to JavaScript:

```dart
@NAPI()
class Point {
  const Point._(this.x);
  final int x;
}

const _origin = Point._(7);

@NAPI()
int coordinate({Point point = _origin}) => point.x;

@NAPI(classPolicy: ClassPolicy.value)
class Selection {
  Selection({this.point = _origin});
  final Point point;
}

@NAPI()
int selectedCoordinate(Selection selection) => selection.point.x;
```

```js
coordinate();                          // 7
coordinate({point: undefined});        // 7
selectedCoordinate({});                // 7
selectedCoordinate({point: undefined}); // 7
```

The original Dart constant supplies the default. This works for named parameters
and the last optional positional parameter of exported functions, static methods,
reference-class constructors and value-class input constructors.

Instance methods still require a public constructor or const binding, preserving
the selected declaration's defaults when a subclass overrides the method. Earlier
optional positional parameters have the same restriction. Function values, type
literals and symbols inside inaccessible defaults remain unsupported.

[Argument defaults](https://github.com/medz/napi/blob/v0.21.0/doc/arguments.md#constant-defaults)

### 🔒 Retain resources inside private defaults

A private default object can now contain resources when each stored resource has
a selected resource view and an accessible const expression or public stored-field
path. The enclosing object itself can keep its constructor private.

These defaults receive the same operation leases as explicit inputs, including
Future and Stream calls and value-class construction. Resources are retained
before later constructors, getters or callbacks run; failures release accepted
uses.

A const default is shared across calls. Once its resource is closing or closed,
omitted calls fail; supply another open resource explicitly. Resource leaves
without an accessible expression remain unsupported.

[Resource defaults](https://github.com/medz/napi/blob/v0.21.0/doc/resources.md#constant-defaults)

Regenerate bindings to use the new defaults. Both targets require Dart 3.13.5;
native packages support macOS arm64 with bridge ABI 15.

[Release on GitHub](https://github.com/medz/napi/releases/tag/v0.21.0)

## 0.20.0

This release lets `buildLibrary` rebuild its own generated modules, bringing
raw bindings into the same repeated-build workflow as generated npm packages.

### 📦 Rebuild raw native and Wasm modules

Run the same build script again after changing your Dart API:

```dart
await buildLibrary(
  library: File('lib/counter.dart').absolute.uri,
  packagesPath: File('.dart_tool/package_config.json').absolute.path,
  output: Directory('bindings'),
);
```

The builder publishes a complete compiled replacement, removes obsolete generated
artifacts, and retains other author files and metadata. This works for Wasm and
native modules. Package and module ownership are separate, so neither build API
can replace the other's output.

Rebuilding requires local macOS APFS or a supported 64-bit Linux ext-family
filesystem or tmpfs. Native builds still require macOS arm64. Windows, network
filesystems and raw output from earlier releases require a fresh directory.
Generated files and the ownership record must remain unmodified.

[Managed rebuilds](https://github.com/medz/napi/blob/v0.20.0/doc/packaging.md#managed-rebuilds)

### Other improvements

- The quick start now walks through building and importing a complete npm package.
  Class and resource guides include runnable usage examples.

Both targets require Dart 3.13.5; native packages use bridge ABI 15.

[Release on GitHub](https://github.com/medz/napi/releases/tag/v0.20.0)

## 0.19.0

This release lets Dart consume JavaScript async iterables returned by callbacks,
preserves custom const collection defaults, and supports rebuilding generated
npm packages on Linux.

### 🔁 Consume async iterables from Dart callbacks

A callback declared with a Dart `Stream` result now accepts a JavaScript
`AsyncIterable`, including an async generator:

```dart
@NAPI()
Future<List<int>> read(Stream<int> Function(int) source) => source(3).toList();
```

```js
await read(async function* (start) {
  yield start;
  yield start + 1;
}); // [3, 4]
```

Dart pulls one item at a time and validates each yielded value. Pausing stops
further pulls; cancelling or failing conversion calls the iterator's optional
`return()` once. Original JavaScript iteration errors retain their identity.

Resource payloads stay retained through iteration. Closing a resource requests
cancellation and waits for accepted iterator work; it cannot force an unresolved
JavaScript Promise to settle. Both native and Wasm use the same mapping.

[Stream callback behavior](https://github.com/medz/napi/blob/v0.19.0/doc/callbacks.md#stream-results)

### 📦 Keep custom const collection defaults

Optional parameters can now use custom const `List` and `Map` implementations
with scalar or structural data elements. Omitting a parameter or supplying
`undefined` preserves the original Dart constant, including nested collections.
Explicit JavaScript inputs keep the ordinary declared collection conversions.

The constant needs an accessible constructor or public const binding. Resources
stored in its fields retain their normal operation leases without evaluating
collection getters or iterators. Reference, value-class and opaque element types
remain unsupported because computed elements need not appear in stored fields.

[Argument defaults and limits](https://github.com/medz/napi/blob/v0.19.0/doc/arguments.md)

### 🐧 Rebuild generated npm packages on Linux

Build and assembly calls can now replace their own managed output on supported
64-bit Linux ext-family filesystems and tmpfs. Replacement uses an atomic
directory exchange and preserves retained author files, permissions, ownership,
ACLs, extended attributes and timestamps for unchanged files. Linux requires
`statx` and extended attribute support; legacy or unsupported output remains
unchanged.

This extends package rebuilding. Native `.node` addons still support macOS
arm64.

[Managed rebuild rules](https://github.com/medz/napi/blob/v0.19.0/doc/packaging.md#managed-rebuilds)

### Other improvements and fixes

- Managed rebuilds can replace explicitly supplied read-only documentation assets
  and preserve read-only `package.json` permissions on Linux.

Regenerate bindings to use the new conversions. Both build targets still require
Dart 3.13.5; native packages use bridge ABI 15.

[Release on GitHub](https://github.com/medz/napi/releases/tag/v0.19.0)

## 0.18.0

This release lets you keep part of a class alias generic, carry JavaScript
payloads through value and resource classes, and use those payloads as Map keys.
Dart handles the surrounding structure while the original JavaScript values
keep their identity.

### 🧩 Keep class aliases partially generic

Fix the Dart type arguments your API needs and leave the payload type open:

```dart
class Pair<A, B> {
  Pair(this.first, this.second);
  A first;
  B second;
}

@NAPI()
typedef IntPair<T> = Pair<int, T>;
```

```js
const payload = {name: 'example'};
const pair = new IntPair(1, payload);

pair.first;              // 1: a Dart int
pair.second === payload; // true: the original JavaScript object
```

TypeScript exposes `IntPair<T>`. The remaining `T` is an opaque payload, not a
runtime Dart specialization: Dart can store and forward it without inspecting
its JavaScript contents.

Aliases can also select nullable and nested payload shapes, such as
`Pair<int, T?>` or `Pair<int, List<T?>>`. Ordinary containers are copied;
opaque leaves retain their identity. Every alias parameter must occur in the
selected type, and ordinary open classes keep their separate specialization
limits.

[Partially open class aliases](https://github.com/medz/napi/blob/v0.18.0/doc/concrete-generics.md#partially-open-class-aliases)

### 📦 Carry payloads through value and resource classes

Generic payloads are no longer limited to reference classes. Value classes can
accept and return them through their declared `<T>` parameters: the surrounding
plain object is copied, while its opaque payloads remain the original
JavaScript values.

Resource classes can store and forward these payloads too, with the existing
cleanup and operation-lease rules. Selected generic resource ancestors may
rename or reorder all type parameters when their cleanup contracts agree.

[Opaque payloads and their limits](https://github.com/medz/napi/blob/v0.18.0/doc/opaque.md)

### 🗝️ Use JavaScript payloads as Map keys

Dart can now group or look up opaque payloads without converting them to
strings. For example, count repeated JavaScript objects by identity:

```dart
@NAPI()
Map<T, int> counts<T>(List<T> values) {
  final result = <T, int>{};
  for (final value in values) {
    result[value] = (result[value] ?? 0) + 1;
  }
  return result;
}
```

```js
const first = {};
const second = {};
const result = counts([first, second, first]);

result.get(first);  // 2
result.get(second); // 1
```

The returned Map is an independent container; its opaque keys retain their
original identity. Opaque keys use JavaScript Map's SameValueZero equality,
including `NaN` and signed zero. Enclosing record and value-class keys still
use Dart equality, and keys that collapse during conversion fail rather than
overwrite an entry.

JS collection handles can also be keys in copied Dart Maps. `JsMap` now accepts
typed function keys under the existing signature-specific function conversion
and identity rules.

[Map key behavior](https://github.com/medz/napi/blob/v0.18.0/doc/opaque.md#map-keys)
and [JS collection handles](https://github.com/medz/napi/blob/v0.18.0/doc/collections.md)

### Other improvements and fixes

- Resource defaults in value-class constructors now participate in operation
  leases. Resources stored in constant defaults are retained, including
  inherited fields; discarded constructor arguments do not acquire extra leases.
- Fix dual-target builds failing with an internal error for open generic value
  classes and partially open value aliases.
- Fix sequential builds reporting an output as locked after the previous build
  has completed.

Regenerate bindings to use the new conversions. Both build targets still require
Dart 3.13.5; native packages support macOS arm64 with bridge ABI 15.

[Release on GitHub](https://github.com/medz/napi/releases/tag/v0.18.0)

## 0.17.0

This release adds Dart function-value exports, more element types for shared
JavaScript collections, and broader callback parameter support. Value-class input
constructors can now be inferred from Dart declarations, so common migrations
only need to remove one annotation option.

> **Upgrading:** `valueConstructor` has been removed. If you use it, see the
> migration examples below before regenerating your bindings.

### 📦 Return Dart functions

Exported Dart APIs can now return closures that JavaScript calls directly.
Captured values and optional parameter defaults stay with the Dart closure:

```dart
@NAPI()
int Function([int]) makeAdder(int delta) =>
    ([int value = 7]) => value + delta;
```

```js
const add = makeAdder(2);

add(3); // 5
add();  // 9: uses the Dart default of 7
```

Function values can also cross through fields, copied containers, and
higher-order signatures, including Future and Stream results. Function identity
is preserved when the input and output conversions agree.

If a closure captures a resource, keep that resource open while the function
uses it. Capturing a resource does not create an implicit operation lease.

[Returned functions and their limits](https://github.com/medz/napi/blob/v0.17.0/doc/callbacks.md#returned-functions)

### 🧩 More shared collection element types

`JsArray` and `JsMap` now support references, resources, binary values, nested
handles, copied structures, value classes, and typed function values.

The sharing model is unchanged: the original JavaScript container is preserved,
and elements are validated when accessed.

Const container defaults can now contain resource objects too, with operation
leases and disposal behavior matching explicitly supplied inputs.

### ↔️ Broader callback parameters

Callbacks now support optional and named parameters, along with binary and
structured payloads and selected class references.

Asynchronous resource leases are tied to the actual callback payloads. A callback
without resource payloads does not extend unrelated resource operations.

### 🔧 Infer value-class input constructors

You no longer need a string to tell napi which constructor to call.

For a public unnamed constructor, remove `valueConstructor`:

```diff
-@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
+@NAPI(classPolicy: ClassPolicy.value)
 class Point {
   final int x;
   Point(this.x);
 }
```

If there is no public unnamed constructor, napi selects the sole public named
constructor or factory.

To explicitly select a constructor or factory, put `@NAPI()` on its declaration:

```diff
 @NAPI(
   classPolicy: ClassPolicy.value,
-  valueConstructor: 'parse',
   valueFields: {'source': 'value'},
 )
 class Label {
   final String value;
+  @NAPI()
   Label.parse(String source) : value = source.trim();
 }
```

The constructor annotation is an explicit selection, not a requirement for every
value class. The `Label` example has only one public named constructor, so it can
also be inferred without the extra annotation.

[Constructor selection rules](https://github.com/medz/napi/blob/v0.17.0/doc/values.md)

### Other fixes

- Fix nullable and non-nullable function values sharing a generated adapter.
- Describe function conversions involving different value-class input and output
  shapes accurately in generated TypeScript.

### Upgrading to 0.17.0

Remove any `valueConstructor` options, select a constructor explicitly where
needed, and regenerate your bindings. If an input constructor cannot be inferred
and none is explicitly selected, the value class is output-only.

[Release on GitHub](https://github.com/medz/napi/releases/tag/v0.17.0)

## 0.16.1

- Fix const-default type-cast failures for package `lib/` files and relative
  reexports. Preserve Dart library identities and diagnose conflicting file/package
  imports before generation. Rebuild generated npm packages after upgrading.

## 0.16.0

- Support const reference and value objects as Dart defaults, directly and inside
  supported List, Map, Dictionary and record defaults. Preserve canonical Dart
  identity, generic types and public factory constructors.
- Use public const variables and static constants for object defaults with private
  constructors or auxiliary Dart values, including private aliases.
- Support direct const resource defaults with the same operation leases and
  disposal behavior as explicit inputs, including Futures, Streams and reentry.
- Refresh usage guides for annotations, external selections, shared JavaScript
  containers and native runtime distribution.

## 0.15.0

- Rebuild binding generation around one `@NAPI()` export model and the separate
  `package:napi/build.dart` API. See [migration notes](doc/annotations.md#migrating-earlier-bindings)
  for changes from the earlier builder and runtime APIs.
- Add experimental native Node-API addons on macOS arm64 alongside Dart Wasm.
  Native builds automatically download and cache the matching precompiled runtime;
  application builds need only the ordinary Dart 3.13.5 SDK.
- Preserve JavaScript constructors, class inheritance and object identity, Dart
  defaults and argument presence, exact UTF-16 strings, and integer precision.
- Convert Lists, Maps, dictionaries, records and configured value classes; support
  structural constant defaults and explicit binary snapshots or shared byte views.
- Support opaque generic payloads, generic methods and concrete generic aliases
  with shared TypeScript declarations across both targets.
- Add Futures and Promises, retained synchronous and asynchronous callbacks,
  bounded async iteration, cooperative cancellation, and resource disposal.
- Share JavaScript Arrays and Maps through explicit `JsArray`/`JsMap` handles,
  including handles nested in copied structures and callback signatures.
- Build complete native, Wasm or dual-target npm packages with automatic loaders,
  matching type declarations and licenses. Rebuild managed packages atomically
  on local macOS APFS.

## 0.14.0

- Support binary Lists with `Uint8Array` elements and independent snapshots.
- Include Dart documentation in generated TypeScript declarations.
- Generate distinct TypeScript names for Dart wildcard parameters.
- Allow source packages with older language versions to use the Dart 3.13.5 build SDK.

Earlier release notes are available in Git history.
