## 0.18.0

Generic payloads now work in value and resource classes and as keys in copied
Maps. Selected class aliases can leave part of their Dart type arguments open.

### Generic values, resources and class aliases

Value and resource classes can store and forward opaque generic payloads using
their declared `<T>` parameters. Selected generic resource ancestors support full
parameter renaming and permutation with compatible cleanup contracts.

A class alias can fix some Dart arguments and expose the remaining parameters:

```dart
class Pair<A, B> {
  Pair(this.first, this.value);
  final A first;
  B value;
}

@NAPI()
typedef IntPair<T> = Pair<int, T>;
```

JavaScript uses `new IntPair(1, payload)`. Alias patterns can also contain nullable
and nested opaque arguments, including Lists, Maps, records and typed functions.
Every alias parameter must occur in the selected type; ordinary open classes
retain their separate specialization limits.

[Generic aliases](https://github.com/medz/napi/blob/v0.18.0/doc/concrete-generics.md)
and [opaque payloads](https://github.com/medz/napi/blob/v0.18.0/doc/opaque.md)

### More Map key types

Opaque values and JS collection handles can now be keys in copied Dart Maps,
including through records, value classes and callbacks:

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

The Map container is copied; opaque payloads and JS handles retain their original
identity. Opaque keys use JS Map's SameValueZero equality, including NaN and signed
zero. Enclosing record/value-class keys still use Dart equality, and keys that
collapse during conversion still fail instead of overwriting an entry.

`JsMap` also accepts typed function keys under the existing function conversion
and identity rules.

[Map key behavior](https://github.com/medz/napi/blob/v0.18.0/doc/opaque.md#map-keys)
and [JS collection handles](https://github.com/medz/napi/blob/v0.18.0/doc/collections.md)

### Defaults and build fixes

- Fix dual-target packages failing with an internal error for open generic value
  classes and partially open value aliases.
- Resource defaults in value-class constructors participate in operation leases.
  Resources are found in actual stored constant state, including inherited
  fields; discarded constructor arguments do not acquire extra leases.
- Fix sequential builds reporting an output as locked after the previous build
  has completed.

Regenerate bindings to use these conversions. Both build targets require Dart
3.13.5; native packages currently support macOS arm64 with bridge ABI 15.

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
