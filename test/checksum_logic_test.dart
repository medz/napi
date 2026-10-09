import 'dart:typed_data';

import 'package:test/test.dart';

import '../example/checksum/checksum.dart';

void main() {
  int reference(Uint8List bytes) {
    var crc = 0xffffffff;
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 1) == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320;
      }
    }
    return crc ^ 0xffffffff;
  }

  test(
    'word blocks and tails match a bitwise reference at every alignment',
    () {
      for (var length = 0; length <= 67; length++) {
        for (var offset = 0; offset < 4; offset++) {
          final backing = Uint8List(length + offset + 4)
            ..fillRange(0, length + offset + 4, 0xa5);
          final bytes = Uint8List.sublistView(backing, offset, offset + length);
          for (var index = 0; index < length; index++) {
            bytes[index] = (index * 31 + length * 7) & 0xff;
          }
          final original = Uint8List.fromList(backing);
          expect(checksum((name: 'view', bytes: bytes)), (
            name: 'view',
            byteCount: length,
            crc32: reference(bytes),
          ), reason: 'length $length, offset $offset');
          expect(backing, original);
        }
      }
    },
  );

  test('empty data has zero bytes and CRC32', () {
    final bytes = Uint8List(0);
    expect(checksum((name: '', bytes: bytes)), (
      name: '',
      byteCount: 0,
      crc32: 0,
    ));
    expect(bytes, isEmpty);
  });

  test('standard CRC32 vector retains its unsigned high bit', () {
    final bytes = Uint8List.fromList('123456789'.codeUnits);
    final original = Uint8List.fromList(bytes);
    final result = checksum((name: 'sample.txt', bytes: bytes));
    expect(result, (name: 'sample.txt', byteCount: 9, crc32: 3421780262));
    expect(result.crc32, greaterThan(0x7fffffff));
    expect(bytes, original);
    expect(checksum((name: 'sample.txt', bytes: bytes)), result);
  });

  test('binary bytes include zero and all high-bit values', () {
    final bytes = Uint8List(256);
    for (var index = 0; index < bytes.length; index++) {
      bytes[index] = index;
    }
    final original = Uint8List.fromList(bytes);
    expect(checksum((name: 'binary', bytes: bytes)), (
      name: 'binary',
      byteCount: 256,
      crc32: 0x29058c73,
    ));
    expect(bytes, original);
  });

  test('a nonzero-offset view excludes surrounding bytes', () {
    final backing = Uint8List.fromList([
      0xde,
      0xad,
      ...'123456789'.codeUnits,
      0xbe,
      0xef,
    ]);
    final original = Uint8List.fromList(backing);
    final bytes = Uint8List.sublistView(backing, 2, 11);
    expect(bytes.offsetInBytes, 2);
    expect(checksum((name: 'view', bytes: bytes)), (
      name: 'view',
      byteCount: 9,
      crc32: 0xcbf43926,
    ));
    expect(backing, original);
  });

  test('names remain exact without trimming or Unicode normalization', () {
    final bytes = Uint8List.fromList('123456789'.codeUnits);
    final original = Uint8List.fromList(bytes);
    for (final name in ['', '-', ' ../ file.bin ', 'e\u0301', 'é', '文件 🚀']) {
      expect(checksum((name: name, bytes: bytes)), (
        name: name,
        byteCount: 9,
        crc32: 0xcbf43926,
      ));
    }
    expect(bytes, original);
  });
}
