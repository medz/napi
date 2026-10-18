# Structural value classes

A value binding describes data copied across the Dart/JavaScript boundary.
Declare its fields and explicitly select the Dart constructor used for inputs:

```dart
import 'package:napi/napi.dart';

@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
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
factory; normal Dart invariants and domain errors apply. Omitting
`valueConstructor` makes a class output-only, including when nested inside a
container. Such a type receives a source diagnostic if used as an input.

[Concrete aliases](concrete-generics.md#structural-value-aliases) can fix real Dart
type arguments before selecting the value policy. Each specialization keeps its
own constructor, recursive field schemas and direction-specific TypeScript
types. Ordinary open generic value classes remain unsupported.

## Mapping

`valueConstructor` uses the original public Dart constructor name: `new` for
unnamed construction, or the named generative/factory constructor's name.
Private or excluded constructors cannot be selected. An abstract class may
select a factory that returns a private implementation.

Every constructor parameter maps to the selected own public field/getter with
exactly the same original Dart name. For different names, configure only the
exceptions:

```dart
@NAPI(
  classPolicy: ClassPolicy.value,
  valueConstructor: 'parse',
  valueFields: {'source': 'value'},
)
class Label {
  final String value;
  Label.parse(String source) : value = source.trim();
}
```

The mapping direction is constructor parameter to field/getter. Member renaming
with `@NAPI(name: 'publicName')` determines the JavaScript property key and does
not change the Dart-name mapping. Input parameter types and output getter types
are checked separately, allowing a constructor to normalize accepted data.
Every parameter must resolve, including optional parameters. Unknown mappings,
excluded/static members and duplicate input property keys are diagnosed.

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

Each object's selected fields/getters are read once per occurrence, in
declaration order, before converting that object's children. Repeated values
produce independent copies and repeat getter evaluation for each occurrence.
The complete Dart tree is snapshotted before host-side integer range, reference
brand and converted Map-key collision checks. A later getter exception therefore
precedes those host-side failures. Getter exceptions stop conversion. An active-path cycle fails; repeated sibling
objects are valid. Recursive type declarations are supported independently of
whether a particular runtime value is cyclic.

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
