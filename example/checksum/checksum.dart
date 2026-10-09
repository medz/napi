import 'dart:typed_data';

import 'package:napi/napi.dart';

typedef FileInput = ({String name, Uint8List bytes});
typedef FileChecksum = ({String name, int byteCount, int crc32});

final _crcTable = _createCrcTable();

Uint32List _createCrcTable() {
  final table = Uint32List(256);
  for (var index = 0; index < table.length; index++) {
    var value = index;
    for (var bit = 0; bit < 8; bit++) {
      value = (value & 1) == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320;
    }
    table[index] = value;
  }
  return table;
}

/// Computes reflected CRC-32 without changing the file name or bytes.
@napi
FileChecksum checksum(FileInput file) {
  var crc = 0xffffffff;
  for (final byte in file.bytes) {
    crc = _crcTable[(crc ^ byte) & 0xff] ^ (crc >> 8);
  }
  return (
    name: file.name,
    byteCount: file.bytes.length,
    crc32: crc ^ 0xffffffff,
  );
}
