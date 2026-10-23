# Resource cleanup

Use a resource class for a Dart object that must be closed explicitly. For
example, a ticker owns a timer that must be cancelled:

```dart
import 'dart:async';
import 'package:napi/napi.dart';

@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Ticker {
  int _ticks = 0;
  late final Timer _timer;

  Ticker() {
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _ticks++);
  }

  int get ticks => _ticks;
  void close() => _timer.cancel();
}
```

```js
import {Ticker} from 'your-package';

const ticker = new Ticker();
console.log(ticker.ticks);
await ticker.close();
```

Cleanup always returns a `Promise<void>`, even when the Dart method returns
`void`. It may need to wait for work already using the resource. Garbage
collection does not call your cleanup method.

## Define cleanup

`cleanup` names an own public Dart method returning `void` or `Future<void>`.
That method must remain exported. It can take the usual supported parameters
and defaults. Renaming its export with `@NAPI(name: 'release')` changes the JS
method to `release`; `cleanup` still names the original Dart method.

A selected subclass inherits its resource contract. All selected views of the
same object must agree on the cleanup method, parameters and defaults. Generic
resource classes support [opaque payloads](opaque.md), and
[concrete aliases](concrete-generics.md#resource-aliases) select real Dart type
arguments. Cleanup can use class parameters but cannot declare its own generic
parameters.

## Close once

The first valid cleanup call starts closing the resource and captures its
arguments. Later valid calls return the same live Promise:

```js
const completion = ticker.close();
completion === ticker.close(); // true
await completion;
ticker.ticks; // throws: Resource is closed
```

While closing, new methods, property access and uses as an input are rejected.
Synchronous operations throw; Future operations reject. Cleanup runs after all
accepted uses finish. Both successful and failed cleanup are terminal: a failed
cleanup is not retried.

Every cleanup call still validates its arguments. An invalid repeat rejects its
own Promise rather than replacing the accepted cleanup. Do not make cleanup
await its own completion.

Returning a closing or closed resource is allowed, so callers can retain its
identity and await cleanup again. It still cannot start a new operation. Ordinary
interface views and recreated wrappers share the same closed state.

## Closing during a call

A method or function using a resource keeps it open through that operation:

- A synchronous call releases it after result conversion.
- A Future call releases it after the public Promise settles, including thenable
  adoption. Dropping the Promise does not cancel the work.
- A Stream transfers the use to its subscription. Closing the resource requests
  cancellation and waits for accepted iteration and delivery to finish.

Receiver and input resources are retained as they are accepted, including inside
Lists, Maps, Dictionaries, records and value classes. Conversion failures release
already accepted uses. Repeated aliases share one resource state.

[JS collection handles](collections.md) retain resource elements when Dart
accesses them. The current exported operation applies after `await` and during
Stream subscription. A detached timer cannot start new resource access after
its exported call has finished. [Callbacks](callbacks.md) have the same
operation lifetime rules.

Resource cleanup itself may accept resources; those inputs stay open through
cleanup. The resource being closed is exempt from retaining itself.

For object results, Promise settlement tracking uses a per-module Node promise
hook. Active modules add hook overhead; it is removed when no observed
operations remain. A callable `then` keeps standard Promise behavior and can
change the fulfillment value. See [Promises](futures.md).

## Constant defaults

A resource with a const constructor can be a [parameter default](arguments.md).
Omission and `undefined` reuse the same canonical Dart object, not a fresh
resource. Once that default is closing or closed, callers must supply another
open resource explicitly.

Resources can also appear in supported container defaults and value-class input
properties. They receive the same lifetime protection as explicit inputs, before
later constructors, getters or callbacks run. A closed default fails before the
value constructor or exported operation starts.

Stored resources in const object defaults are discovered from their stored
fields, including private and inherited fields. Discarded constructor arguments
are not retained. A resource needs a selected resource view and an accessible
const expression or public stored-field path; otherwise the build reports
`NAPI_DEFAULT`. Computed getters and iterators are not run to discover stored
resources. Custom const collections retain the [element restrictions](arguments.md#constant-defaults).

## Direct Dart use

Custom integrations can use the controls from `package:napi/runtime.dart`:

```dart
final control = ResourceControl.forObject(raw);
final operation = ResourceOperation();
try {
  operation.retain(control);
  // Finish all work using raw, including result conversion.
} finally {
  operation.release();
}
await control.dispose(() => raw.close());
```

`operation.run(body)` makes the operation current through the body's async
continuations; it does not extend its lifetime beyond `release()`. Releasing is
idempotent. Cleanup runs in the first disposal call's Dart Zone, and cached
completion follows Dart's normal error-zone rules.
