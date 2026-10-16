import 'dart:io';
import 'dart:math';

import 'package:napi/napi.dart';

export 'maps.dart';
export 'structural_values.dart';

@NAPI()
int randomValue() => Random.secure().nextInt(1024);
@NAPI()
String executable() => Platform.executable;

void main() => throw StateError('Business main must not run');

// Public names must not collide with generated loader bindings or globals.
@NAPI(name: 'createRequire')
int exportRequire() => 1;
@NAPI(name: 'bindings')
int exportBindings() => 2;
@NAPI(name: 'globalThis')
int exportGlobal() => 3;
@NAPI(name: 'URL')
int exportUrl() => 4;
