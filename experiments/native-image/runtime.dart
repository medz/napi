import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'macho.dart';

/// Internal embedder entry points from the pinned SDK's own symbol table.
/// These are SDK-private C++ functions, so changing the SDK requires checking
/// their signatures as well as finding their new addresses.
final class RuntimeSymbols {
  RuntimeSymbols.parse(Uint8List runtime, Uint8List symbols, MachOImage image)
    : _runtime = runtime,
      _imageBase = image.imageBase {
    const runtimeHash =
        '5c123cea40111eb8ce564d3af2b41a68db7b605adc90cb23ca0a1f49ece81252';
    const symbolsHash =
        'd467d02a642d602b03e9cab12c8aef5801a9fbb7f6d7b14d60512069903d032a';
    if (sha256.convert(runtime).toString() != runtimeHash ||
        sha256.convert(symbols).toString() != symbolsHash) {
      throw StateError(
        'Expected the verified Dart 3.13.5 macOS arm64 runtime and .sym file',
      );
    }

    // SDK runtime/vm/native_symbol_posix.cc, NativeSymbols::Entry:
    // uint32 offset, uint32 size, uint32 string_table_offset.
    final data = ByteData.sublistView(symbols);
    final count = data.getUint32(0, Endian.little);
    final strings = 4 + count * 12;
    if (strings > symbols.length) {
      throw const FormatException('Truncated runtime symbol table');
    }
    for (var i = 0; i < count; ++i) {
      final entry = 4 + i * 12;
      final offset = data.getUint32(entry, Endian.little);
      final nameOffset = strings + data.getUint32(entry + 8, Endian.little);
      final end = symbols.indexOf(0, nameOffset);
      if (end < nameOffset || offset >= runtime.length) {
        throw const FormatException('Invalid runtime symbol');
      }
      final name = utf8.decode(symbols.sublist(nameOffset, end));
      _offsets.putIfAbsent(name, () => <int>{}).add(offset);
    }

    // Check the symbol table's base against independently parsed Mach-O exports.
    for (final name in [
      '_Dart_Initialize',
      '_Dart_CreateIsolateGroup',
      '_Dart_RootLibrary',
      '_Dart_ShutdownIsolate',
    ]) {
      if (address(name) != image.symbolAddress(name)) {
        throw StateError('Runtime symbols disagree with Mach-O export $name');
      }
    }
  }

  final Uint8List _runtime;
  final int _imageBase;
  final _offsets = <String, Set<int>>{};

  /// The pointer read by Platform.executable. SetExecutableName was inlined in
  /// this SDK, so recover its storage from the verified getter instructions.
  int get executableNameSlot {
    final getter = address('dart::bin::Platform::GetExecutableName');
    final data = ByteData.sublistView(_runtime);
    final offset = getter - _imageBase;
    final adrp = data.getUint32(offset, Endian.little);
    final load = data.getUint32(offset + 4, Endian.little);
    final ret = data.getUint32(offset + 8, Endian.little);
    final baseRegister = adrp & 31;
    if (adrp & 0x9f000000 != 0x90000000 ||
        baseRegister == 31 ||
        load & 0xffc00000 != 0xf9400000 ||
        load & 31 != 0 ||
        (load >>> 5) & 31 != baseRegister ||
        ret != 0xd65f03c0) {
      throw StateError('Unexpected Platform::GetExecutableName instructions');
    }
    var pages = ((adrp >>> 5) & 0x7ffff) << 2 | (adrp >>> 29) & 3;
    if (pages & 0x100000 != 0) pages -= 0x200000;
    final displacement = ((load >>> 10) & 0xfff) * 8;
    final slot = (getter & -4096) + pages * 4096 + displacement;
    var command = 32;
    for (var i = 0; i < data.getUint32(16, Endian.little); ++i) {
      if (data.getUint32(command, Endian.little) == 0x19) {
        final start = data.getUint64(command + 24, Endian.little);
        final size = data.getUint64(command + 32, Endian.little);
        final protections = data.getUint32(command + 60, Endian.little);
        if (protections & 2 != 0 && slot >= start && slot + 8 <= start + size) {
          return slot;
        }
      }
      command += data.getUint32(command + 4, Endian.little);
    }
    throw StateError(
      'Executable name pointer is outside writable runtime data',
    );
  }

  /// Returns the unslid virtual address for the SDK's exact symbol name.
  /// For example: `dart::embedder::InitOnce`.
  int address(String name) {
    final matches = _offsets[name];
    if (matches == null || matches.length != 1) {
      throw StateError('Missing or ambiguous runtime symbol: $name');
    }
    return _imageBase + matches.single;
  }
}
