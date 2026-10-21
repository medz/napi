# Structural value classes

A value binding describes data copied across the Dart/JavaScript boundary.
Declare its fields and constructor in Dart:

```dart
import 'package:napi/napi.dart';

@NAPI(classPolicy: ClassPolicy.value)
class Point {
  final int x;
  final int y;
  Point(this.x, {this.y = 0}) {
    if (x < 0) throw ArgumentError('x must be nonnegative');
  }
}

@NAPI()
Point move(Point point) => Point(point.x + 1, y: point.y);
```

```ts
import {move} from 'generated-package';
import type {Point} from 'generated-package';

const result: Point = move({x: 3}); // {x: 4, y: 0}
```

`Point` is a TypeScript output type. No JavaScript `Point` constructor is
exported. Each accepted input calls the selected real Dart constructor or
factory; normal Dart invariants and domain errors apply. Annotate one public
constructor or factory with `@NAPI()` to select the input entry point. That
selection takes priority over an unnamed constructor. Multiple explicitly
selected callable constructors produce an ambiguity diagnostic listing them.
External libraries use the same rule through `ExternalMember.constructor`.

Without an explicit selection, the public unnamed constructor is used, or the
sole public named constructor or factory when no unnamed constructor is
available. Private, excluded, external and non-factory abstract constructors are
not callable inputs. If automatic selection finds no unambiguous constructor,
the class is output-only. Direct input uses then receive a source diagnostic,
including when nested inside an ordinary copied container.

[Concrete aliases](concrete-generics.md#structural-value-aliases) can fix real Dart
type arguments before selecting the value policy. Each specialization keeps its
own constructor, recursive field schemas and direction-specific TypeScript
types. Ordinary open generic value classes remain unsupported.

## Mapping

Each constructor parameter supplies an input property and its Dart type. A
same-name readable member supplies its public rename, if any; a parameter need
not have a matching output field or getter. An abstract class may use its public
factory to return a private implementation.

`valueFields` optionally maps a constructor parameter to a differently named
readable member when both directions should use that member's public name:

```dart
@NAPI(
  classPolicy: ClassPolicy.value,
  valueFields: {'source': 'value'},
)
class Label {
  final String value;
  Label(this.value);
  @NAPI()
  Label.parse(String source) : value = source.trim();
}
```

The mapping direction is constructor parameter to field/getter. Member renaming
with `@NAPI(name: 'publicName')` determines the JavaScript property key and does
not change the Dart-name mapping. Input parameter types and output getter types
are checked separately, allowing a constructor to normalize accepted data.
Unknown mappings, excluded/static members and duplicate input property keys are
diagnosed.

Output contains selected own readable fields/getters in declaration order.
Input accepts only constructor-mapped fields; additional derived output getters
do not become accepted input fields. Unknown input fields are rejected.
Unannotated methods do not participate in structural output. An explicitly
included method produces a source diagnostic; use `exclude: true` to omit it.

Optional fields use the Dart parameter default when absent or explicitly
`undefined`. Required fields reject both absence and `undefined`; only nullable
fields accept `null`. Input optionality and output required fields have separate
TypeScript shapes. Numeric policies compose through fields and recursion,
including an enclosing `@NAPI(bigint: true)` function.
Defaults may include [const objects](arguments.md),
directly or inside supported containers; they remain Dart constants.
Input properties may also default to resources, directly or inside built-in
containers. Omission and undefined select the canonical Dart constant, while an
explicit nullable null remains null. The current [resource operation](resources.md)
retains those defaults before later fields or callbacks run; failed conversion
releases its leases. Already closed defaults fail before construction.
When a library exports resources, const value-object defaults may contain only
scalar fields or built-in containers of scalars. Supply objects with reference or
nested value-class fields explicitly instead.

## Validation and construction order

For each parameter, conversion first validates and snapshots the complete raw
shape and its scalar/reference leaves. It then materializes typed containers
and calls value constructors in postorder. A later invalid raw field prevents
all value constructors for that parameter. Earlier parameters may already have
been constructed when a later parameter fails. Calls that use the generated
JavaScript class/reference facade first check argument presence and direct
reference arguments, before constructing any value parameter. A present invalid
scalar or a nested invalid leaf still fails during its own parameter conversion.

Constructor/domain failures and Dart Map equality/hash failures occur during
materialization. They preserve earlier constructor side effects; conversion
provides no transactional rollback of Dart business effects. The exported
business function is called only after all parameters convert successfully.
Domain exceptions remain ordinary JavaScript `Error` values, while generated
shape/type/range errors retain their contextual property paths.

Snapshotting requires temporary storage proportional to the visited shape.
The structural work, depth and cycle limits also apply to value classes.

## Output and composition

For ordinary value outputs, selected fields/getters are read once per occurrence, in
declaration order, before converting that object's children. Repeated values
produce independent copies and repeat getter evaluation for each occurrence.
The complete Dart tree is snapshotted before host-side integer range, reference
brand and converted Map-key collision checks. A later getter exception therefore
precedes those host-side failures. Getter exceptions stop conversion. An active-path cycle fails; repeated sibling
objects are valid. Recursive type declarations are supported independently of
whether a particular runtime value is cyclic.

Explicit [JS collection handles](collections.md) convert each getter result before
reading the next getter, retaining its reference and resource leaves for that
operation.

Value fields compose with nullable scalars, Lists, records, Maps, Dictionaries,
other values, selected reference classes, binary values and JS collection handles.
A value object has no JavaScript brand or identity cache. A private object
implementing two selected value
interfaces can be projected through either declared shape. Reference leaves
keep the same module-owned live-wrapper identity as direct reference calls.
A failed output rolls back only newly claimed reference wrappers, preserving
previously exposed references and ordinary GC behavior.

The shared structural descriptor policy, contextual errors and depth/work
limits are described in [structural values](structural.md). Reference object
identity and lifecycle remain described in [reference classes](classes.md).
