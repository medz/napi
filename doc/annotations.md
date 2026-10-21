# Selecting bindings

The source frontend resolves a Dart library and its public export namespace.
Only the resolved `NAPI` class from this package selects a declaration. Prefixes,
reexports of the annotation, and typedefs are resolved through the analyzer;
a different class also named `NAPI` does not select anything.

## Selection syntax

| Placement | Syntax | Selection |
| --- | --- | --- |
| Public top-level function | `@NAPI()` | Function, using its Dart name |
| Public top-level function | `@NAPI(bigint: true)` | Function, mapping all Dart `int` parameters/results to JavaScript `bigint` |
| Generic public function or ordinary reference class | `@NAPI()` | Generic parameters come from the Dart declaration and carry unchanged JS payloads |
| Public function or class | `@NAPI(name: 'PublicName')` | Declaration, with an explicit export name |
| Public class | `@NAPI()` | Class and its own public constructors, fields, accessors and methods |
| Public concrete class typedef | `@NAPI()` | A class with fixed Dart type arguments |
| Public const generic function instantiation | `@NAPI()` | A function with fixed Dart type arguments |
| Member of an annotated class | `@NAPI(name: 'publicName')` | Override that member's name |
| Member of an annotated class | `@NAPI(exclude: true)` | Exclude that member from the JavaScript API |

There is one uppercase annotation class, with no lowercase constant. A typedef
alias of the constructor is resolved normally; a constant object used as an
annotation is diagnosed rather than silently ignored. Private
annotated declarations, multiple annotations, `name` together with `exclude`,
member annotations without an annotated owning class, and annotations on other
syntax are diagnosed at source. An annotated field declaration must declare one
field. `exclude` is only valid on class members.

Generated classes inherit the supported contracts of their selected ancestors;
unselected ancestors do not automatically add exports. See
[reference classes](classes.md) and [concrete hierarchies](concrete-generics.md).
An explicit override is an own declaration and is selected normally. Static and
instance members retain that distinction. A getter/setter pair for the same
property may share its public name. Excluding one accessor
leaves the other selected. Inconsistent renames of a selected accessor pair and
unrelated members with colliding names are rejected.

Both backends generate selected unnamed generative/factory reference constructors
with `new`; named constructors/factories become static methods using their Dart
name unless renamed. [Concrete aliases](concrete-generics.md) select fixed class
or callable type arguments without adding configuration to the original source.

## Class policies

`@NAPI()` classes default to `ClassPolicy.reference`. Explicit policies use the
same annotation and external configuration:

```dart
@NAPI(classPolicy: ClassPolicy.value)
class Point { Point(this.x); final int x; }

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource { Future<void> close() async {} }
```

`ExternalClass('Resource', config: NAPI(classPolicy: ClassPolicy.resource,
cleanup: 'close'))` describes the same policy without modifying the dependency.
`cleanup` is required only for resources and selects an own public instance
method by its original Dart name. Renaming the method changes its JavaScript name,
not which Dart method performs cleanup. The method must have a supported cleanup
signature and remain selected for export.

Both targets generate [reference classes](classes.md), including
[Future-returning calls](futures.md), and
[structural value classes](values.md). Value inputs use the public unnamed
constructor, or the sole public named constructor/factory. Parameters determine
input properties; matching readable members supply their public renames, with
optional `valueFields` overrides for different names. Without an unambiguous
callable constructor, a value class is output-only. Runtime generation
validates these mappings before compilation. Ordinary reference classes do not
gain disposal. Both targets generate [resource bindings](resources.md): cleanup
uses the selected method's export name and supported parameters, returns
`Promise<void>` for Dart `void` or `Future<void>`, and waits for accepted operation
leases. Excluding the cleanup method prevents a resource build.

Direct function-typed inputs generate [callbacks](callbacks.md) on both targets,
including constructors, methods, setters, Future-returning exports and resource
cleanup. The Dart function's reachability retains its JS callback, with weak
adapter identity across calls. Callback parameters must be required positional.
Arguments and results support scalars, JS collection handles, and Lists/records
containing them; results may also be void or Future-based. Handle elements may
use an enclosing declaration's opaque parameters. Nullable outer inputs preserve
presence rules. Exporting a callback, nesting a callback, callback-owned generic
parameters and bare opaque callback payloads remain unsupported.

## Library resolution

The selected entry is a file library. Ordinary imports do not select exports.
Reexports respect `show`/`hide`, including declarations in parts. Generated calls
use that public Dart surface; diagnostics identify the original declaration.
Dartdoc is retained in TypeScript declarations. Defaults are evaluated in their
declaring library, including private and imported constants; see
[argument defaults](arguments.md).

`typedef Count = int` remains an int; `double` is not accepted as int.
Conditional imports and exports resolve for the
requested Dart Wasm or native AOT target. A [dual-target build](packaging.md)
resolves both independently and compares their public contracts.

## Building

Building checks supported signatures before creating output. Functions support
positional/named parameters and results using `bool`, `String`, `double`,
`int`, `BigInt`, and their nullable forms, plus recursively nested `List`, `Map`, explicit `Dictionary` and
record values with supported leaves.
Generic parameters are read directly from the Dart declaration. Supported
direct generic payloads and matching generic references preserve unchanged JS
values using a private carrier; business code must follow the storage/forwarding
contract. No repeated type-parameter list is required.
See [opaque eligibility, presence and ownership](opaque.md) for supported bounds,
signature positions and remaining generic combinations. External selections use
the same inferred mapping without extra configuration.
`@NAPI(bigint: true)` selects fixed JavaScript `bigint` representation for every
Dart `int` parameter/result of that function, including nullable ints and typedefs.
It does not change other scalar types; Dart `BigInt` always uses JavaScript
`bigint`. This policy also applies inside supported callback signatures.
See [scalar conversion semantics](scalars.md) and
[optional/named arguments and defaults](arguments.md). Other types, external
functions and unsupported class shapes produce source diagnostics; selected
unsupported declarations are never dropped.

Use `buildPackage` for a fresh npm package, as shown in [package assembly](packaging.md).
`buildLibrary` produces raw artifacts and defaults to Wasm. Run either build API
in a separate Dart VM script; this example selects the direct-Wasm path:

```dart
import 'dart:io';
import 'package:napi/build.dart';

Future<void> main() async {
  await buildLibrary(
    library: File('lib/bindings.dart').absolute.uri,
    output: Directory('output'),
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
  );
}
```

The source library imports only `package:napi/napi.dart` for `NAPI`. The separate
build entrypoint exposes the command, its result and source diagnostics without
pulling analyzer or host-only build dependencies into the Wasm source graph.

Direct-Wasm consumers import generated exports normally:

```js
import { add } from './module.wasm';
```

The direct-Wasm path supports normal imports without consumer initialization.
Both targets implement [reference classes](classes.md), [resource cleanup](resources.md),
[Future](futures.md), [callback](callbacks.md) and [Stream](streams.md) contracts.
Their remaining unsupported combinations produce build diagnostics.

## External selections

Select declarations from an installed dependency in the build script. Its source
stays unchanged: no annotations, wrapper signatures or copied defaults are needed.
For example, with `collection` in the consumer's dependencies:

```dart
import 'dart:io';
import 'package:napi/build.dart';

Future<void> main() async {
  await buildLibrary(
    library: Uri.parse('package:collection/collection.dart'),
    output: Directory('output'),
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    external: const ExternalLibrary([
      ExternalFunction('compareNatural', config: NAPI(name: 'compareNames')),
    ]),
  );
}
```

Run `dart run build.dart`, then import the generated API normally:

```js
import { compareNames } from './output/module.wasm';
console.log(compareNames('item2', 'item10') < 0); // true
```

External selections use the same `NAPI` configuration, resolved signatures,
defaults, documentation and semantic IR as annotations. Public reexports respect
`show`/`hide`; missing, private, ambiguous and colliding selections are diagnosed.
`ExternalClass` and `ExternalMember.constructor`/`method`/`getter`/`setter`/`field`
also describe class selections and overrides. Both annotation and external
selections support scalar and structural functions, reference classes and value
classes and resources on both backends. Value construction and resource cleanup
use the explicit mappings described above.

## Migrating earlier bindings

When upgrading from 0.14.x, change the Dart dependency to `napi: ^0.16.0` and
use Dart **3.13.5** exactly. The compiler adapter now pins that SDK version.

1. Replace `@napi` with `@NAPI()`. Keep importing `package:napi/napi.dart` in
   business sources. Use [external selections](#external-selections) when the
   original dependency cannot be edited.
2. Replace `dart run napi:build ...` with a separate `tool/build.dart` that imports
   `package:napi/build.dart` and calls `buildPackage`. Pass the source URI, output
   directory, package configuration and npm `name`/`version` metadata, then run
   `dart run tool/build.dart`. See the [complete build example](../README.md#build-a-package).
3. Review `Map<String, T>` boundaries: they now accept and return JavaScript
   `Map`, rather than plain objects. To retain an object-shaped API, declare
   `Dictionary<T>` instead and wrap Dart map results with `Dictionary<T>(map)`.
   It implements Dart `Map<String, T>`; both mappings copy their contents.
   See [structural values](structural.md).
4. Build into a fresh output directory for the first upgrade. A 0.14 output lacks
   the ownership record required for [managed rebuilds](packaging.md#managed-rebuilds)
   and is rejected rather than overwritten. Repackage all generated files and
   declarations; do not retain the old `module.imports.mjs` filename in custom
   copying or bundling rules.
5. Existing Wasm package-root, `package-name/module.wasm` and relative
   `./module.wasm` imports remain supported, with the generated companion files.
   Wasm is still the default target. Choose `target: BuildTarget.native` for
   native, or include both `targets` and select their package root with `target`.
   Dual packages also expose `/native` and `/wasm`; imports initialize the chosen
   backend without an application setup call or automatic fallback. See
   [dual-target packages](packaging.md#explicit-dual-target-packages) and the
   currently supported [native platform](native.md).
