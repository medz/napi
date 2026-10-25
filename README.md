# napi

Node-API bindings for Dart.

Import the raw FFI bindings with:

```dart
import 'package:napi/sys/node.dart' as node;
```

These bindings expose Node-API handles, status codes and native function
signatures. Calls require a valid environment supplied by a Node-API host.

See the [native image experiment](experiments/native-image/README.md) for the
standalone Dart AOT addon prototype.
