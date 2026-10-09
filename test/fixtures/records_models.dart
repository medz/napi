import 'dart:typed_data';

typedef Name = String;
typedef Age = int;
typedef Bytes = Uint8List;
typedef MaybeBytes = Bytes?;

typedef User = ({Name name, Age age, bool? active});
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

typedef Packet = ({Name name, Bytes payload});
typedef PacketAlias = Packet;
typedef MaybePacket = PacketAlias?;
typedef ReexportPacket = Packet;
typedef ByteFields = ({Bytes first, MaybeBytes maybe, Bytes second});
