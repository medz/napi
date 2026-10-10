import 'dart:typed_data';

import 'package:napi/napi.dart';

@napi
Uint8List echoBytes(Uint8List bytes) => bytes;

@napi
List<Uint8List> echoByteList(List<Uint8List> values) => values;

@napi
Future<Uint8List> echoBytesAsync(Uint8List bytes) async {
  await Future<void>.value();
  return bytes;
}

@napi
Future<List<Uint8List>> echoByteListAsync(List<Uint8List> values) async {
  await Future<void>.value();
  return values;
}
