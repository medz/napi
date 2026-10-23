# Classes

Annotate a Dart class to expose a JavaScript class backed by the same Dart
object. Constructors, methods and properties execute in Dart.

```dart
@NAPI()
class Counter {
  Counter([this.value = 0]);
  Counter.seed(this.value);

  int value;
  int increment([int amount = 1]) => value += amount;
}
```

```js
import {Counter} from '@scope/counter';

const counter = new Counter();
counter.increment();       // 1
counter.value = 40;
counter.increment(2);      // 42
Counter.seed(10).value;    // 10
```

Public constructors, methods, fields and accessors are exported automatically.
Use [member annotations](annotations.md#rename-or-exclude-a-member) to rename or
exclude one. Parameters and results use the normal [type conversions](structural.md)
and [default values](arguments.md).

## Constructors and factories

The unnamed constructor uses JavaScript `new`. Named constructors and factories
become static methods, as `Counter.seed` does above. An abstract class can expose
a factory returning a concrete Dart object.

If no unnamed constructor is selected, the JavaScript class cannot be called
with `new`; use one of its exported named constructors or factories instead.
A factory returning an already exposed Dart object returns its existing wrapper.

## Properties and methods

A mutable Dart field has a JavaScript getter and setter; a final field is
readonly. Explicit Dart getters and setters become JavaScript properties.
Methods returning `Future<T>` return [Promises](futures.md), and methods returning
`Stream<T>` return [async iterators](streams.md).

An extracted instance method needs its receiver:

```js
const increment = counter.increment;
increment.call(counter); // works
increment();             // TypeError
```

Only genuine compatible wrappers can be used as receivers or reference
arguments. Lookalike objects, Proxy wrappers and objects from another backend or
independently loaded package instance are rejected.

## Identity and lifetime

Returning the same Dart object reuses its live JavaScript wrapper, including
when it appears inside a copied List, Map or record. Different Dart objects
have different wrappers.

A reachable wrapper keeps its Dart object alive. If Dart still owns the object
after its JS wrapper is collected, returning it again creates a wrapper without
calling its constructor. Garbage collection never calls an application cleanup
method; use a [resource class](resources.md) when cleanup must be explicit.

For native objects storing JS payloads or callbacks, break cycles by clearing
the payload or unregistering the callback. See [generic payload ownership](opaque.md#ownership).

## Inheritance and interfaces

A selected Dart subclass inherits its selected superclass's JavaScript
prototype. Unselected intermediate classes are skipped. Compatible selected
interface members are available on a concrete wrapper, but interfaces do not
add JavaScript prototype chains. Parameter and receiver checks use actual Dart
membership, so `instanceof` is not the full compatibility test.

An object implementing unrelated selected interfaces can expose their combined
methods through one wrapper. That wrapper has an ordinary object prototype and
does not pass those interfaces' `instanceof` checks. Conflicting conversions or
defaults for the same exported name cause `TypeError` when such an object is
first exposed. TypeScript does not invent inheritance between unrelated interfaces.

Defaults belong to the selected declaration. Calling a child's override uses
its selected defaults; borrowing a base method uses the base defaults. A private
unselected override does not change them. Static members and named constructors
do not inherit.

Ordinary JavaScript subclasses can extend the generated class and use JS private
fields. A factory's existing wrapper takes precedence over a newly supplied
prototype.

See [generic classes](opaque.md#reference-inheritance) and [concrete aliases](concrete-generics.md)
for supported generic inheritance.

## TypeScript

Reference classes have nominal types: an object literal with the same fields is
not a valid class instance. Selected subclasses remain assignable to their
selected ancestors. For plain objects copied by value, use a
[value class](values.md) instead.
