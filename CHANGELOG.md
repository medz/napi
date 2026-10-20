## 0.16.1

- Keep a library's canonical Dart import identity when generating const object
  defaults, including builds started from a file inside a package's `lib/`.

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
