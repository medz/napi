# Parameters and defaults

Dart parameters become JavaScript arguments. Optional parameters keep their Dart
defaults; named parameters become a final options object.

## Optional parameters

```dart
@NAPI()
int add([int left = 1, int right = 2]) => left + right;
```

```js
add();             // 3
add(4);            // 6
add(undefined, 4); // 5
add(0, 0);         // 0
add(null);         // TypeError: left is not nullable
```

Omission and `undefined` select the default independently for each ordinary
optional parameter. Values such as `false`, `0` and `''` are passed through.
Extra JavaScript arguments are ignored.

A required nullable parameter still needs an argument: `String? value` accepts
`null`, but rejects omission and `undefined`. An optional nullable parameter
without an explicit default uses Dart's `null` default.

Generic payloads have different presence rules: an explicitly supplied
`undefined` or `null` stays a payload. Only omission selects an optional payload's
default. See [generic payloads](opaque.md#presence-and-typescript).

## Named parameters

```dart
@NAPI()
int choose(int base, {required int? value, int extra = 42}) =>
    base + (value ?? 0) + extra;
```

```js
choose(1, {value: null});               // 43
choose(1, {value: 0, extra: undefined}); // 43
choose(1, {value: 0, extra: 0});         // 1
choose(1, {});                         // TypeError: value is required
```

The options object can be omitted only when every named parameter is optional.
It must be a plain or null-prototype object. Unknown keys, symbol keys and
accessor properties are rejected; inherited properties are ignored. Passing
`null` as the options object is an error.

## Constant defaults

Defaults are evaluated in the Dart library where they are declared. Private and
imported constants work, and the selected default stays in Dart:

```dart
const _fallbacks = <String, List<int>>{'small': [1, 2]};

@NAPI()
int first({Map<String, List<int>> values = _fallbacks}) =>
    values['small']!.first;
```

```js
first();                         // 1
first({values: undefined});      // 1
first({values: new Map([['small', [7]]])}); // 7
```

Lists, Maps, Dictionaries and records can contain scalars, null and selected
reference or value objects. An object default can use a public const constructor
or a public const binding. For example, an exported `Point` can use
`Point point = const Point(0, 0)`. A public const binding can also name an object
whose constructor or implementation class is private. Helper classes used only
inside a default do not need to be exported to JavaScript.

Named parameters and the last optional positional parameter can also use a
private constant or constructor. When that argument is omitted, the binding
lets the original Dart callable supply its default:

```dart
@NAPI()
class Point {
  const Point._(this.x);
  final int x;
}

@NAPI()
int coordinate({Point point = const Point._(7)}) => point.x;
```

```javascript
coordinate(); // 7
coordinate({ point: undefined }); // 7
```

This also works for static methods, reference-class constructors and value-class
input constructors. Stored resources must have an accessible const expression or
public stored-field path, as described below. Function values, type literals and
symbols remain unsupported in inaccessible defaults. Instance methods still need
a public constructor or const binding so overrides cannot change the selected
declaration's defaults. Earlier optional positional parameters also need a public
constructor or const binding.

Defaults preserve the actual Dart constant, including its type, insertion order
and canonical identity. Returning a default uses the normal result conversion.
Custom const List/Map implementations work with scalar or structural data
elements; reference, value-class and opaque element types remain unsupported.

[Resource defaults](resources.md#constant-defaults) keep resources open through
accepted operations. Stored resources need an accessible const expression or
public stored-field path. Collection getters and iterators are not run to find
those stored resources.

Non-null opaque payload defaults are unsupported. Compatible empty containers
such as `List<T> = const []`, or null elements in nullable payload containers,
are supported. Other unsupported, inaccessible, incompatible or excessively
large defaults produce `NAPI_DEFAULT` during the build.

[Returned Dart functions](callbacks.md#returned-functions) have additional
restrictions on positional defaults and resource defaults.

## TypeScript

Ordinary optional arguments and options properties accept `undefined`. Required
nullable properties accept `null` and still require a value.

For optional generic payload properties such as `value?: T | null`, enable
`strictNullChecks` and `exactOptionalPropertyTypes` to reject an explicit
`undefined` when it is not part of `T`. Without the latter option, TypeScript's
normal optional-property rules allow it. Runtime presence rules are unchanged.
