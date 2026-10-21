# Binary snapshots

`Uint8List` and `ByteBuffer` use independent byte snapshots on native Node-API
and Dart Wasm. The Dart type selects the JavaScript representation; no additional
annotation option is needed.

```dart
import 'dart:typed_data';
import 'package:napi/napi.dart';

@NAPI()
Uint8List changeFirst(Uint8List bytes) {
  if (bytes.isNotEmpty) bytes[0] = 7;
  return bytes;
}
```

```js
import {changeFirst} from 'generated-package';

const input = new Uint8Array([1, 2, 3]);
const output = changeFirst(input);
console.log([...input]);  // [1, 2, 3]
console.log([...output]); // [7, 2, 3]
input[1] = 9;            // output still contains 2 at index 1
```

## Representations

| Dart declaration | JavaScript / TypeScript | Copied bytes |
| --- | --- | --- |
| `Uint8List` | `Uint8Array<ArrayBuffer>` | The view's visible range |
| `ByteBuffer` | `ArrayBuffer` | The complete buffer |

A Node `Buffer` is accepted as a `Uint8List` input. Output is an ordinary
`Uint8Array`, including when the input was a `Buffer`. An offset view copies only
its selected bytes, producing a tight output at offset zero. It does not expose
the surrounding bytes of a pooled Buffer. A `ByteBuffer` explicitly represents
its complete backing storage; use `Uint8List` to select a window.

Both types support nullable values, ordinary optional/named defaults, class
members, and leaves inside supported Lists, Maps, Dictionaries, records and value
classes. Aliases and reexports resolve to the same Dart type. `Future` and
`Stream` results use the same binary conversion. Generic opaque payloads retain
their existing identity semantics: a `T` containing a JavaScript typed array is
still an opaque value, rather than an inferred binary snapshot.

Typed [callbacks](callbacks.md) accept both types directly and inside Lists and
records, including Future results, with the same independent snapshot policy.
Other typed-data declarations produce build diagnostics.
A `ByteBuffer` obtained from another Dart typed list
is supported; its bytes retain their original layout without numeric conversion.

## Snapshot timing and ownership

Each accepted input becomes independent storage during conversion, before that
value reaches Dart business code. A structural argument is fully snapshotted
before its value-class constructors or Dart Map key `hashCode`/`==` run.
Parameters follow the existing
conversion order: a constructor for an earlier parameter can affect the original
JavaScript value of a later parameter before that later parameter is converted.
This is not an atomic snapshot of the entire call.

Dart may retain a converted input after the call or across suspension. Later
JavaScript mutation, detachment or resizing of the original input does not alter
the accepted copy. Conversely, later Dart mutation does not alter an already
returned JavaScript snapshot. Repeated references produce independent snapshots,
including repeated leaves in one structural value.

Future output conversion occurs when the actual Future completes. Stream values
are snapshotted on event admission, so subsequent mutation of the source bytes
cannot change an accepted item. Existing resource leases and accepted-delivery
rules continue to apply. Copies need no borrowed-buffer expiration or explicit
release API; storage follows ordinary reachability in its owning runtime.

## Input validity

Brand and window checks use captured intrinsics. Cross-realm Uint8Arrays and
ArrayBuffers are accepted; proxies, fake prototypes, other typed-array element
types and DataViews are rejected. Own `buffer`, `byteOffset`, `byteLength`,
`length`, iterator and constructor properties cannot substitute storage or run
conversion hooks.

| Input state at conversion | Result |
| --- | --- |
| Valid empty buffer or view | Independent empty snapshot |
| Valid fixed or resizable ArrayBuffer window | Snapshot of its current visible bytes |
| Valid length-tracking view | Snapshot of the currently visible window |
| Detached buffer/view | TypeError |
| Out-of-bounds view after resizing | TypeError, including apparent zero-length views |
| SharedArrayBuffer or growable SharedArrayBuffer backing | TypeError |
| Byte length above 2,147,483,647 | RangeError |

Required nullable inputs accept `null`, while required `undefined` or omission
fails. Optional inputs use their declared default on omission or `undefined`.
Invalid inputs fail before business entry; Future exports reject through their
normal Promise boundary. A later valid call remains usable.

## Copying cost

Native copies valid windows in bulk into independent Dart storage and copies
Dart output into fresh JS storage. Its short typed-data access intervals contain
no JavaScript callbacks or allocation. Wasm wraps a private input snapshot using
the pinned SDK and writes output into newly allocated host storage. Per-element
Wasm bridge work and any structural admission copies are real costs; these APIs
do not make a zero-copy claim.

Both backends require the pinned Dart SDK and supported Node runtime. See
[native requirements](native.md) and [supported toolchains](../README.md#verify).

Use [SharedBytes](shared-bytes.md) for explicit live shared views. Its checked
adapter preserves host storage and handles later detachment/resizing without
retaining native pointers. Ordinary Uint8List and ByteBuffer keep the snapshot
contract above.
