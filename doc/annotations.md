# Annotation frontend

The source frontend resolves a Dart library and its public export namespace.
Only the resolved `NAPI` class from this package selects a declaration. Prefixes,
reexports of the annotation, and typedefs are resolved through the analyzer;
a different class also named `NAPI` does not select anything.

## Selection syntax

| Placement | Syntax | Selection |
| --- | --- | --- |
| Public top-level function | `@NAPI()` | Function, using its Dart name |
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
not assign constructors or factories a JavaScript runtime representation. Class
runtime generation, constructibility and concrete factory APIs are later work. Class aliases are normalized as class
declarations, including their mixin and synthetic constructor metadata.

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
expressions are source metadata, not copied executable JavaScript. Later presence
and conversion work chooses how to apply defaults and named-parameter options.
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
backend capabilities before creating output: currently only nongeneric top-level
functions with required positional, nonnullable int inputs and int results are
supported. Optional/named parameters, nullable values, other types, external
functions and classes produce source diagnostics; selected unsupported
declarations are never dropped.

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
strict TypeScript checks and atomic output publication remain unchanged. Broader
conversions, exact argument-presence execution, external bindings and class
runtime engines belong to subsequent work.
