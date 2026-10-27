import 'dart:typed_data';

import 'package:napi/napi.dart';

ByteBuffer? _lastBuffer;
ByteData? _lastData;

@NAPI()
ByteBuffer echoBuffer(ByteBuffer value) => _lastBuffer = value;

@NAPI()
ByteData echoData(ByteData value) => _lastData = value;

@NAPI()
ByteBuffer lastBuffer() => _lastBuffer!;

@NAPI()
ByteData lastData() => _lastData!;

@NAPI()
ByteData subview() =>
    ByteData.view(Uint8List.fromList([91, 1, 2, 3, 92]).buffer, 1, 3);

@NAPI()
List<ByteData?> echoViews(List<ByteData?> values) => values;

@NAPI()
ByteData Function(ByteData) bounceData(ByteData Function(ByteData) callback) =>
    callback;
