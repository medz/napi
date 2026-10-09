import 'dart:typed_data';

import 'package:napi/napi.dart';

typedef One = ({int id});
typedef Four = ({bool active, int id, String name, double score});
typedef Sixteen = ({
  bool active0,
  bool active1,
  bool active2,
  bool active3,
  int id0,
  int id1,
  int id2,
  int id3,
  String name0,
  String name1,
  String name2,
  String name3,
  double score0,
  double score1,
  double score2,
  double score3,
});
typedef BytePacket = ({String name, Uint8List payload});

@napi
int answer() => 42;

@napi
One echoOne(One value) => value;

@napi
Four echoFour(Four value) => value;

@napi
Sixteen echoSixteen(Sixteen value) => value;

@napi
Future<One> echoOneAsync(One value) async => value;

@napi
Future<Four> echoFourAsync(Four value) async => value;

@napi
Future<Sixteen> echoSixteenAsync(Sixteen value) async => value;

@napi
BytePacket echoPacket(BytePacket value) => value;

@napi
Uint8List echoPacketPayload(Uint8List value) => value;
