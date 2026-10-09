import 'dart:typed_data';

typedef User = ({String name, int age, bool? active});
typedef UserAlias = User;
typedef NullableUser = User?;
typedef MaybeUserAlias = NullableUser;
typedef ReexportUser = User;

typedef Mixed = ({
  bool flag,
  int count,
  double value,
  String text,
  bool? maybeFlag,
  int? maybeCount,
  double? maybeValue,
  String? maybeText,
});

typedef SpecialFields = ({
  String constructor,
  String prototype,
  String then,
  double $value,
});

typedef Packet = ({String name, Uint8List payload});
typedef PacketAlias = Packet;
typedef MaybePacket = PacketAlias?;
typedef ReexportPacket = Packet;
typedef ByteFields = ({Uint8List first, Uint8List? maybe, Uint8List second});
