part of 'batch.dart';

typedef BatchPart = ({int code, String message});

@napi
List<BatchPart?>? echoPart(List<BatchPart?>? values) => values;

@napi
Future<List<BatchPart?>?> echoPartAsync(List<BatchPart?>? values) async =>
    values;

typedef BatchPacket = ({int code, Uint8List? payload});

@napi
List<BatchPacket?>? echoPartPackets(List<BatchPacket?>? values) => values;

@napi
Future<List<BatchPacket?>?> echoPartPacketsAsync(
  List<BatchPacket?>? values,
) async => values;
