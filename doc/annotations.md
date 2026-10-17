# Annotation frontend

The source frontend resolves a Dart library and its public export namespace.
Only the resolved `NAPI` class from this package selects a declaration. Prefixes,
reexports of the annotation, and typedefs are resolved through the analyzer;
a different class also named `NAPI` does not select anything.

## Selection syntax

| Placement | Syntax | Selection |
| --- | --- | --- |
| Public top-level function | `@NAPI()` | Function, using its Dart name |
| Public top-level function | `@NAPI(bigint: true)` | Function, mapping all Dart `int` parameters/results to JavaScript `bigint` |
| Public function or class | `@NAPI(name: 'PublicName')` | Declaration, with an explicit export name |
| Public class | `@NAPI()` | Class and its own public constructors, fields, accessors and methods |
| Member of an annotated class | `@NAPI(name: 'publicName')` | Override that member's name |
| Member of an annotated class | `@NAPI(exclude: true)` | Exclude that member; retain its declaration metadata |

There is one uppercase annotation class, with no lowercase constant. A typedef
alias of the constructor is resolved normally; a constant object used as an
annotation is diagnosed rather than silently ignored. Private
annotated declarations, multiple annotations, `name` together with `exclude`,
member annotations without an annotated owning class, and annotations on other
syntax are diagnosed at source. An annotated field declaration must declare one
field. `exclude` is only valid on class members.

Inherited members are not automatically selected. An explicit override is an own
declaration and is selected normally. Static and instance members retain that
distinction. Fields are represented once, rather than duplicated as synthetic
getters/setters. Explicit getters and setters have separate declaration identities;
a pair for the same property may share its public name. Excluding one accessor
leaves the other selected. Inconsistent renames of a selected accessor pair and
unrelated members with colliding names are rejected.

Constructor metadata distinguishes unnamed, named, factory, const and implicit
constructors. A named constructor/factory retains its Dart member name unless
renamed; an unnamed constructor has no assigned public member name. This does
not assign all constructors or factories a JavaScript runtime representation.
Both backends generate selected unnamed generative/factory reference constructors
with `new`; named constructors/factories become static methods. Class aliases are normalized as
class declarations, including their mixin and synthetic constructor metadata.

## Class policies

`@NAPI()` classes default to `ClassPolicy.reference`. Explicit policies use the
same annotation and external configuration:

```dart
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class Point { Point(this.x); final int x; }

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource { Future<void> close() async {} }
```

`ExternalClass('Resource', config: NAPI(classPolicy: ClassPolicy.resource,
cleanup: 'close'))` describes the same policy without modifying the dependency.
`cleanup` is required only for resources and selects an own public instance
method by its original Dart name. Its existing member metadata retains the full
signature, including generics, defaults and `Future` returns. Renaming or excluding
that member from public exports does not change its cleanup identity.

Both targets generate [reference classes](classes.md), including
[Future-returning calls](futures.md), and
[structural value classes](values.md). Value inputs require an explicit
`valueConstructor` (`new` or the original named constructor); parameters match
own readable members by Dart name, with `valueFields` for different names.
Without a selected constructor, a value class is output-only. Runtime generation
validates these mappings before compilation. Ordinary reference classes do not
gain disposal. Both targets generate [resource bindings](resources.md): cleanup
uses the selected method's export name and supported parameters, returns
`Promise<void>` for Dart `void` or `Future<void>`, and waits for accepted operation
leases. Excluding the cleanup method is descriptive metadata, but prevents a
resource build; it does not silently expose a hidden method.

## Resolution and metadata

The selected entry is a file library. Ordinary imports do not select exports.
Reexports respect `show`/`hide`, and selected declarations retain their origin
library and original source locations, including declarations in parts. The entry
URI, exported Dart surface, declaration origin and callable Dart path are separate
metadata. Generated calls import the selected surface, so a reexport does not
accidentally call a nonexistent declaration in the entry file.

The IR preserves documentation, line/column and offsets, nullable types, generic
arguments and bounds, typedef identity, function/record types, parameter kinds,
explicit defaults, initializing/super formals, fields and member modifiers. Default
expressions remain source metadata. Evaluated scalar constants drive generated
Dart defaults and named-parameter options without copying source expressions.
Wildcard parameters retain their positional slots, including repeated wildcard
type parameters. Synthetic callback parameters have no invented source span;
their source is absent. No analyzer elements, AST nodes or types leave the frontend.

The analyzer dependency is pinned. Its Wasm platform view is isolated in the
frontend, matching the pinned Dart SDK rather than treating a JavaScript numeric
view as the Dart type system. In particular, `typedef Count = int` remains an int;
`double` is not accepted as int. Conditional exports are resolved for this Wasm
platform.

## Discovery versus building

`AnnotationFrontend.read` normalizes declarations and validates selections even
when no runtime engine exists for their signatures. Building separately checks
backend capabilities before creating output: nongeneric top-level functions
support positional/named parameters and results using `bool`, `String`, `double`,
`int`, `BigInt`, and their nullable forms, plus recursively nested `List`, `Map`, explicit `Dictionary` and
record values with supported leaves.
`@NAPI(bigint: true)` selects fixed JavaScript `bigint` representation for every
Dart `int` parameter/result of that function, including nullable ints and typedefs.
It does not change other scalar types; Dart `BigInt` always uses JavaScript
`bigint`. See [scalar conversion semantics](scalars.md) and
[optional/named arguments and defaults](arguments.md). Other types, external
functions and unsupported class shapes produce source diagnostics; selected
unsupported declarations are never dropped.

`buildLibrary` connects discovery to the existing direct-Wasm build pipeline.
Use its build-time entrypoint in a separate Dart VM script:

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

The scalar fixture now uses annotations, including renamed functions and a
reexported entry library. Real Node consumers still use:

```js
import { add } from './module.wasm';
```

The actual `.wasm` exports, direct installed-package entry, safe-integer checks,
strict TypeScript checks and atomic output publication remain unchanged.
Complete class/lifetime engines remain subsequent work; the current
constructor/member and reference conversion contract is documented in
[reference classes](classes.md).

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
