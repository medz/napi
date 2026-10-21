# Shared byte views

Use `SharedBytes` when Dart and JavaScript must access the same Uint8Array
storage. Ordinary `Uint8List` and `ByteBuffer` bindings continue to produce
[independent snapshots](binary.md). The Dart type selects the policy; no extra
annotation metadata is needed.

```dart
import 'package:napi/napi.dart';

@NAPI()
SharedBytes increment(SharedBytes bytes) {
  if (bytes.length != 0) bytes[0] = (bytes[0] + 1) & 255;
  return bytes;
}

@NAPI()
SharedBytes create(int size) => SharedBytes.allocate(size);
```

```js
import {increment, create} from 'generated-package';
const input = new Uint8Array([1, 2]);
console.log(increment(input) === input); // true
console.log(input[0]);                  // 2
const allocated = create(16);            // zero-filled host storage
```

The public JavaScript type is `Uint8Array<ArrayBuffer>`. Node Buffers and foreign
realm Uint8Arrays are accepted and retain their original object identity.
Returning a retained input returns that same view, including its offset and
prototype. A Dart allocation returns an ordinary, fixed-size Uint8Array. The
generated module installs its allocator automatically before business entry,
including when `SharedBytes` is used only inside a function whose signature has
ordinary scalar types. Timers may allocate after initialization. There is no
standalone Dart VM allocator outside an initialized binding runtime.

## Storage by direction

| Source and declaration | JavaScript to Dart | Dart to JavaScript |
| --- | --- | --- |
| `Uint8List` / `ByteBuffer` | Independent Dart snapshot | Independent host snapshot |
| Existing JS view as `SharedBytes` | Checked adapter retains that view | Same original view; mutations remain shared |
| `SharedBytes.allocate` in Dart | Later calls may pass its returned view back | New host-backed view; the retained Dart adapter shares its bytes |
| Ordinary Dart byte storage requested as shared | No implicit conversion | Unsupported; use a snapshot or allocate shared storage explicitly |

This matrix is identical on native and Wasm. Shared backing is an ArrayBuffer;
SharedArrayBuffer backing is not supported. A Dart-created shared view starts
with host storage, so exporting it does not reinterpret Dart heap memory.

## Operations

| Dart operation | Behavior |
| --- | --- |
| `SharedBytes.allocate(length)` | New zero-filled fixed-size host buffer |
| `length`, `bytes[index]`, `bytes[index] = value` | Check and access the current window |
| `subview(start, [end])` | New fixed-length view sharing the selected current range |
| `toUint8List([start, end])` | Independent copy of the selected current range |
| `write(Uint8List source, {offset: 0})` | Copy ordinary Dart bytes into this window |
| `copyFrom(SharedBytes source, {sourceOffset: 0, targetOffset: 0, length})` | Bulk shared-to-shared copy, including overlapping ranges |

End positions are exclusive. An omitted end uses the current length. An omitted
copy length uses the source's current remaining length. Explicit negative
positions, invalid ranges and indexed writes outside 0–255 throw RangeError;
writes do not truncate values or partially modify an invalid range. Lengths are
limited to 2,147,483,647 bytes. Allocation remains subject to host memory limits.

Indexed operations cross the host boundary. Prefer the bulk methods for larger
ranges. Native bulk copies use the existing scoped byte-copy transport; Wasm
ordinary-Dart-to-host staging currently writes each byte through the pinned SDK.
Shared-to-shared `copyFrom` uses a captured Uint8Array bulk operation on both
targets. `toUint8List` and `write` intentionally copy; indexed access, subviews
and shared binding input/output preserve live storage.

## Current windows and invalidation

Every operation validates the current backing and window. A fixed view keeps its
declared range; a length-tracking view follows its resizable ArrayBuffer. Shrink
can make a view out of bounds, and later regrowth can make it valid again.
`subview` always fixes its length at creation. A valid empty range is supported.
Detached and out-of-bounds views throw TypeError, including cases where normal
metadata getters report zero. Growing an ordinary WebAssembly.Memory can detach
its old ArrayBuffer; retained adapters then fail safely on access.

SharedArrayBuffer and growable SharedArrayBuffer backing are rejected. Proxies,
fake typed-array prototypes, DataViews and other element kinds are rejected.
Brand/window access uses captured host intrinsics and does not consult the
view's own metadata, iterator, constructor or species hooks. No buffer is locked
against transfer or resizing, and no persistent native pointer is retained.

Input admission validates a structural root before its Dart constructors run.
Later callbacks can invalidate the admitted live view; subsequent operations
observe that invalidation. Output serialization runs Dart getters before host
validation, following the existing structural output order. An invalid output
fails at that validation boundary.

## Identity and lifetime

The same view reuses the same reachable Dart adapter within one module. A weak
identity cache does not retain the adapter merely because the original JS view
is still alive. A Dart root retains the view; dropping all adapter roots allows
ordinary cleanup. Subviews have distinct identities and share backing storage.
Module instances and Workers have independent adapters and runtime owners.

Nullable values, optional/default arguments, class members and supported
structural containers use the existing conversion rules. `Future<SharedBytes>`
hands the original view to the Promise resolver. A callable `then` on that view
can determine a different fulfillment value under [standard Promise resolution](futures.md).
Stream admission validates and retains the view; it does not freeze its bytes. Mutations
before or after delivery remain visible. The IteratorResult wrapper keeps an
item's `then` property from being assimilated. Resource close waits for accepted
delivery acknowledgments and outstanding operations, and cancels subscriptions
before business cleanup.

Native follows the existing explicit ownership contract: a cycle crossing a JS
view's custom properties and a Dart owner must be broken by application code.
Automatic collection of arbitrary cross-heap cycles is not promised. Garbage
collection does not invoke business cancellation or resource cleanup.

Typed [callbacks](callbacks.md) accept `SharedBytes` directly and inside Lists
and records, including Future results. They retain the original JS view and
observe live bytes; later access still checks detachment and bounds.

This type is a checked host adapter, not a `Uint8List` subclass; arbitrary ordinary
Dart storage cannot be reinterpreted as shared host backing. Allocator support
is included in generated modules even when their exported signatures contain
no `SharedBytes`. See [native requirements](native.md) and
[supported toolchains](../README.md#verify).
