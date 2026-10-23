# Explicit cancellation

A direct Dart `AbortSignal` parameter maps to JavaScript's native `AbortSignal`
on both targets. Import the type from `package:napi/napi.dart`; the compiler
recognizes that declaration's identity, including aliases and reexports.

```dart
import 'dart:async';
import 'package:napi/napi.dart';

@NAPI()
Future<int> delayedAdd(int value, {required AbortSignal signal}) async {
  signal.throwIfAborted();
  final done = Completer<int>();
  final timer = Timer(const Duration(seconds: 1), () => done.complete(value + 1));
  final remove = signal.onAbort(() {
    timer.cancel();
    if (done.isCompleted) return;
    try {
      signal.throwIfAborted();
    } catch (error, stack) {
      done.completeError(error, stack);
    }
  });
  try {
    return await done.future;
  } finally {
    remove();
    timer.cancel();
  }
}
```

```ts
import {delayedAdd} from '@scope/example';
const controller = new AbortController();
const result = delayedAdd(41, {signal: controller.signal});
controller.abort('user stopped');
try {
  await result;
} catch (reason) {
  console.assert(reason === 'user stopped');
}
```

The public Dart interface has three members:

```dart
abstract interface class AbortSignal {
  bool get aborted;
  void throwIfAborted();
  void Function() onAbort(void Function() listener);
}
```

`aborted` and `throwIfAborted()` read current host state, including during
synchronous JavaScript callback reentry before an abort notification has drained.
An uncaught check preserves the exact JavaScript `signal.reason`, without cloning,
stringification or thenable assimilation. Dart can catch and rethrow its private
exception carrier. There is no public raw-JavaScript reason getter. As with native
JavaScript, `controller.abort(undefined)` creates the host's default `AbortError`.

`onAbort` schedules each registration at most once on its valid Dart owner and
registration zone. A thrown listener error goes to that zone's uncaught-error
handler; it does not automatically reject an unrelated business Future. The
returned function removes the registration idempotently, including before a
queued notification is delivered. Registration after an abort also schedules
one notification. Relative microtask order across the two targets is unspecified.

## Completion and ownership

Cancellation is cooperative for an ordinary Future. The example stops its timer
before completing its Future. An API with asynchronous shutdown must await that
shutdown before completing. An API that ignores or recovers from the request may
still return a successful result. The binding never adds a `Promise.race`, a
synthetic `.cancel()` member, or an extra signal parameter to ordinary exports.

Signals remain usable while Dart retains them in a field, collection, closure or
listener-removal function. The end of one export call does not invalidate a signal
or remove another business registration. Remove business listeners when they are
no longer needed. One module reuses a live adapter for the same source signal;
separate modules have separate adapters and registrations.

The source signal alone does not keep its Dart adapter or callbacks alive. The
host listener and identity cache hold weak references to the adapter. The last
registration's removal detaches the host listener immediately; garbage collection
can remove an unreachable adapter's leftover listener later. Finalizers perform
only internal reference cleanup. Native arbitrary cross-heap cycles retain the
[explicit ownership-break contract](opaque.md).

[Resource cleanup](resources.md) continues to await an ordinary pending Future
and its actual JavaScript settlement. Aborting its signal does not release its
leases early. Closing an owner cannot abort a caller-owned controller. Business
code must connect any additional cancellation operation it promises.

## Stream subscriptions and races

A Stream export with an explicit signal input connects that signal to the
adapter's subscription. Multiple signal inputs request the same once-only
cancellation. Stream return and owner close share the same cancellation path.

| Event | Observable outcome |
| --- | --- |
| Signal is already aborted at admission | After input validation and before business entry, a Future export returns a rejected genuine Promise; a synchronous export or Stream factory throws the exact reason. |
| Ordinary Future receives abort while running | Business listeners receive a request. The actual Future determines completion; no stop is inferred from notification alone. |
| Future result has already been accepted | Later abort cannot replace that result, including while a returned root thenable is still settling. |
| Stream receives abort before first read | It never listens to the source. One read rejects with the exact reason, then reads are done. |
| Active Stream receives abort first | Unpaired buffered items are discarded, accepted deliveries remain intact, and the subscription cancels once. After cancellation and earlier delivery acknowledgements, one pending/later read rejects with the reason; subsequent reads are done. |
| Source failure, natural completion, return or owner close is observed first | That terminal state wins. A later abort does not replace its error or result. |
| Cancellation or resource cleanup fails | Read cancellation retains the abort/source error. `return()` reports subscription cancellation failure; owner close gives business cleanup failure priority, then the existing first cancellation failure. |
| Worker/environment teardown | Internal roots and pending deliveries are discarded or rendered inert. No business cancellation runs in a dead environment. |

Stream termination removes only the binding's registrations. Other Dart listeners
and retained signals stay valid. Cancelling one subscription does not promise that
a broadcast producer or another subscriber stopped. The full demand, buffering,
error and acknowledgement rules remain in [Stream exports](streams.md).

## Supported declarations and host values

Direct inputs work in synchronous calls, constructors, setters, Future exports
and Stream exports, with ordinary optional/named/default/nullability rules.
TypeScript uses `globalThis.AbortSignal`, protecting it from exported names that
shadow `AbortSignal`. Signals in containers, callback payloads or outputs receive
build diagnostics. A method named `cancel` or a parameter named `signal` does not
enable this mapping by itself.

The Node boundary uses the native AbortSignal brand checks and rejects proxies,
plain objects and prototype-only impostors. Own properties named `aborted` or
`reason` do not replace the captured getters. Manually dispatching an `abort`
event without an actual state change does not notify Dart or consume the next
real abort. Another listener's `stopImmediatePropagation()` does not suppress a
real abort notification.

Both backends require the pinned Dart SDK. See [native builds](native.md) and
[supported toolchains](../README.md#requirements).
