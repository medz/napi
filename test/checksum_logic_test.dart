import 'dart:typed_data';

import 'package:test/test.dart';

import '../example/checksum/checksum.dart';

void main() {
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
