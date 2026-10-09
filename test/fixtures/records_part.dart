part of 'records.dart';

typedef PartValue = ({int code, String message});

@napi
PartValue echoPart(PartValue value) => value;

@napi
Future<PartValue> echoPartAsync(PartValue value) async {
  await Future<void>.value();
  return value;
}

@napi
PartValue? echoPartNullable(PartValue? value) => value;

@napi
Future<PartValue?> echoPartNullableAsync(PartValue? value) async => value;

typedef PartPacket = ({int code, Uint8List? payload});

@napi
PartPacket echoPartPacket(PartPacket value) => value;

@napi
Future<PartPacket?> echoPartPacketAsync(PartPacket? value) async => value;
