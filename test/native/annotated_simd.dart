import 'dart:typed_data';

import 'package:napi/napi.dart';

@NAPI()
Float32x4 addFloat32(Float32x4 value) => value + Float32x4.splat(1);

@NAPI()
Int32x4 addInt32(Int32x4 value) => value + Int32x4(1, 1, 1, 1);

@NAPI()
Float64x2 addFloat64(Float64x2 value) => value + Float64x2.splat(1);

@NAPI()
Float32x4List echoFloat32List(Float32x4List values) => values;

@NAPI()
Int32x4List echoInt32List(Int32x4List values) => values;

@NAPI()
Float64x2List echoFloat64List(Float64x2List values) => values;

@NAPI()
Float32x4List subview() {
  final values = Float32x4List(3);
  values[0] = Float32x4.splat(91);
  values[1] = Float32x4(1, 2, 3, 4);
  values[2] = Float32x4.splat(92);
  return Float32x4List.view(values.buffer, 16, 1);
}

@NAPI()
Float32x4 Function(Float32x4) bounceFloat32(
  Float32x4 Function(Float32x4) callback,
) => callback;
