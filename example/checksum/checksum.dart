import 'dart:typed_data';

import 'package:napi/napi.dart';

typedef FileName = String;
typedef FileBytes = Uint8List;
typedef Crc32 = int;

typedef FileInput = ({FileName name, FileBytes bytes});
typedef FileChecksum = ({FileName name, int byteCount, Crc32 crc32});

final _crcTable = _createCrcTable();

Uint32List _createCrcTable() {
  final table = Uint32List(1024);
  for (var index = 0; index < 256; index++) {
    var value = index;
    for (var bit = 0; bit < 8; bit++) {
      value = (value & 1) == 0 ? value >> 1 : (value >> 1) ^ 0xedb88320;
    }
    table[index] = value;
  }
  for (var slice = 1; slice < 4; slice++) {
    for (var index = 0; index < 256; index++) {
      final previous = table[(slice - 1) * 256 + index];
      table[slice * 256 + index] = (previous >> 8) ^ table[previous & 0xff];
    }
  }
  return table;
}

/// Computes reflected CRC-32 without changing the file name or bytes.
@napi
FileChecksum checksum(FileInput file) {
  var crc = 0xffffffff;
  final bytes = file.bytes;
  var offset = 0;
  if (bytes.length >= 4) {
    final words = ByteData.sublistView(bytes);
    while (offset + 4 <= bytes.length) {
      crc ^= words.getUint32(offset, Endian.little);
      crc =
          _crcTable[768 + (crc & 0xff)] ^
          _crcTable[512 + ((crc >> 8) & 0xff)] ^
          _crcTable[256 + ((crc >> 16) & 0xff)] ^
          _crcTable[crc >> 24];
      offset += 4;
    }
  }
  while (offset < bytes.length) {
    crc = _crcTable[(crc ^ bytes[offset++]) & 0xff] ^ (crc >> 8);
  }
  return (
    name: file.name,
    byteCount: file.bytes.length,
    crc32: crc ^ 0xffffffff,
  );
}
