# Export Dart APIs

Add `@NAPI()` to a public Dart function or class:

```dart
import 'package:napi/napi.dart';

@NAPI()
int add(int left, int right) => left + right;

@NAPI()
class Counter {
  Counter([this.value = 0]);
  int value;
  int increment() => ++value;
}
```

```js
import {add, Counter} from 'your-package';

add(1, 2); // 3
new Counter().increment(); // 1
```

Build the library with `buildPackage`, as shown in the
[quick start](../README.md#build-a-package). Keep the build script separate from
the source library: source files import `package:napi/napi.dart`, and the build
script imports `package:napi/build.dart`.

An annotated class exports its own public members. Inherited members require
the ancestor to be selected too; see [class inheritance](classes.md#inheritance-and-interfaces).
Reexported annotated declarations are also selected, respecting Dart's `show`
and `hide`.
Ordinary imports do not add exports. Private declarations cannot be exported.
Dart documentation comments appear in the generated TypeScript declarations.

## Rename or exclude a member

Use `name` to choose a JavaScript name, and `exclude` to hide a class member:

```dart
@NAPI(name: 'Counter')
class DartCounter {
  DartCounter();

  @NAPI(name: 'increment')
  int next() => ++_value;

  @NAPI(exclude: true)
  void reset() => _value = 0;

  int _value = 0;
}
```

Member annotations require an annotated class. Do not combine `name` and
`exclude`. Getter and setter names for one property must agree; unrelated
members cannot share an exported name. The build reports invalid selections at
the original declaration.

## Choose a class representation

| Annotation | JavaScript API | Use for |
| --- | --- | --- |
| `@NAPI()` | Class instance | State, methods and object identity |
| `@NAPI(classPolicy: ClassPolicy.value)` | Plain object | Copied input and output data |
| `@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')` | Class with asynchronous cleanup | Files, connections and other resources |

See [classes](classes.md), [value objects](values.md) and [resources](resources.md)
for examples. Resource cleanup names the original Dart method, even if its JS
export is renamed.

## Numbers and generic parameters

Dart `int` uses JavaScript `number` and checks the safe-integer range. Use
`@NAPI(bigint: true)` on a top-level function or concrete callable const to map
every `int` in its supported signature to signed 64-bit JavaScript `bigint`.
This option is not supported on class members. Dart `BigInt` always uses `bigint`.
See [numbers and strings](scalars.md).

Generic parameters come from the Dart declaration; no extra name list is
needed. Open generics store and forward [opaque JS payloads](opaque.md).
Use [class aliases or const callable instantiations](concrete-generics.md) when
an export needs specific Dart type arguments.

## Bind an existing library

Select public declarations in the build script when you cannot annotate the
source. For example, add `collection` to your Dart dependencies and build its
natural-order comparator:

```dart
import 'dart:io';
import 'package:napi/build.dart';

Future<void> main() async {
  await buildPackage(
    library: Uri.parse('package:collection/collection.dart'),
    output: Directory('npm-package'),
    packagesPath: File('.dart_tool/package_config.json').absolute.path,
    metadata: {'name': '@scope/natural-sort', 'version': '0.0.0'},
    external: const ExternalLibrary([
      ExternalFunction('compareNatural', config: NAPI(name: 'compareNames')),
    ]),
  );
}
```

```js
import {compareNames} from '@scope/natural-sort';
compareNames('item2', 'item10') < 0; // true
```

`ExternalClass` selects a class. Its `members` can use
`ExternalMember.constructor`, `.method`, `.getter`, `.setter` or `.field` to
apply member configuration. External selections use the same `NAPI` options,
types and defaults as annotated sources. The original library stays unchanged.
Both backends resolve conditional imports for their own target; dual-target
packages require matching public APIs.

<a id="migrating-earlier-bindings"></a>

## Migrating from 0.14

Upgrade napi and use Dart 3.13.5, then:

1. Replace `@napi` with `@NAPI()`.
2. Replace `dart run napi:build ...` with a build script calling `buildPackage`.
3. Use JavaScript `Map` for Dart `Map` parameters and results. For plain objects,
   use `Dictionary<T>`; see [structural values](structural.md).
4. Build into a fresh directory. Older output lacks the ownership record used
   by managed rebuilds. Repackage the complete generated output.

Wasm remains the default. Existing package-root, `/module.wasm` and relative
`.wasm` imports remain supported. See [packaging](packaging.md) to select native
or include both targets.

`valueConstructor` was removed in 0.17. Constructors are now inferred from the
Dart declaration or selected by annotating the constructor itself. See
[value-class constructors](values.md).
