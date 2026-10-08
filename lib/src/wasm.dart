import 'dart:convert';
import 'dart:typed_data';

enum WasmImportKind { function, table, memory, global, tag }

/// The original host binding and its unique rewritten ES module export name.
final class WasmImport {
  const WasmImport({
    required this.module,
    required this.name,
    required this.kind,
    required this.alias,
  });

  final String module;
  final String name;
  final WasmImportKind kind;
  final String alias;
}

final class RewrittenWasm {
  const RewrittenWasm({required this.bytes, required this.imports});

  final Uint8List bytes;

  /// Host imports only. Builtins and string constants need no JS host binding.
  final List<WasmImport> imports;
}

/// Makes a Dart Wasm module's host dependencies resolvable by native Wasm ESM.
///
/// Only the import section is rebuilt. All other section bytes, including GC
/// types, code, custom sections, and their original length encodings, survive
/// unchanged. This checks framing and import descriptors, not the full module's
/// type system or code; the WebAssembly engine performs that validation.
RewrittenWasm rewriteImports(
  Uint8List bytes, {
  String hostModule = './module.imports.mjs',
}) {
  if (hostModule.isEmpty) throw ArgumentError.value(hostModule, 'hostModule');
  const header = [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0];
  if (bytes.length < header.length ||
      Iterable.generate(header.length).any((i) => bytes[i] != header[i])) {
    throw FormatException(
      'Invalid WebAssembly magic or version 1 header',
      bytes,
    );
  }

  final reader = _Reader(bytes, start: header.length);
  final output = BytesBuilder(copy: false)
    ..add(bytes.sublist(0, header.length));
  final imports = <WasmImport>[];
  var sawImports = false;
  while (!reader.isDone) {
    final start = reader.offset;
    final id = reader.byte('section ID');
    final length = reader.u32('section length');
    final end = reader.offset + length;
    reader.require(length, 'section payload');
    if (id != 2) {
      output.add(Uint8List.sublistView(bytes, start, end));
    } else {
      if (sawImports) reader.fail('Duplicate import section');
      sawImports = true;
      final section = _Reader(bytes, start: reader.offset, end: end);
      final count = section.u32('import count');
      if (count > (end - section.offset) ~/ 4) {
        section.fail('Import count exceeds the section payload');
      }
      final rewritten = BytesBuilder(copy: false)..add(_u32(count));
      for (var index = 0; index < count; index++) {
        final module = section.name('import module');
        final name = section.name('import name');
        final descriptorStart = section.offset;
        final kind = section.importDescriptor();
        final descriptor = Uint8List.sublistView(
          bytes,
          descriptorStart,
          section.offset,
        );
        final String target;
        final String alias;
        if (module.isEmpty) {
          if (kind != WasmImportKind.global) {
            section.fail('Dart string constants must be global imports');
          }
          target = 'wasm:js/string-constants';
          alias = name;
        } else if (module == 'wasm:js-string' ||
            module == 'wasm:js/string-constants') {
          target = module;
          alias = name;
        } else {
          target = hostModule;
          alias = '_i$index';
          imports.add(
            WasmImport(module: module, name: name, kind: kind, alias: alias),
          );
        }
        rewritten
          ..add(_name(target))
          ..add(_name(alias))
          ..add(descriptor);
      }
      if (!section.isDone) section.fail('Trailing bytes in import section');
      final payload = rewritten.takeBytes();
      output
        ..addByte(2)
        ..add(_u32(payload.length))
        ..add(payload);
    }
    reader.offset = end;
  }
  return RewrittenWasm(
    bytes: output.takeBytes(),
    imports: List.unmodifiable(imports),
  );
}

Uint8List _u32(int value) {
  final output = BytesBuilder(copy: false);
  do {
    final byte = value & 0x7f;
    value >>= 7;
    output.addByte(value == 0 ? byte : byte | 0x80);
  } while (value != 0);
  return output.takeBytes();
}

Uint8List _name(String value) {
  final encoded = utf8.encode(value);
  return (BytesBuilder(copy: false)
        ..add(_u32(encoded.length))
        ..add(encoded))
      .takeBytes();
}

final class _Reader {
  _Reader(this.bytes, {int start = 0, int? end})
    : offset = start,
      end = end ?? bytes.length;

  final Uint8List bytes;
  final int end;
  int offset;

  bool get isDone => offset == end;

  Never fail(String message) =>
      throw FormatException('$message at byte $offset', bytes, offset);

  void require(int length, String what) {
    if (length < 0 || length > end - offset) fail('Truncated $what');
  }

  int byte(String what) {
    require(1, what);
    return bytes[offset++];
  }

  int u32(String what) {
    var value = 0;
    for (var index = 0; index < 5; index++) {
      final next = byte(what);
      if (index == 4 && next > 0x0f) fail('Overflowing u32 LEB128 for $what');
      value |= (next & 0x7f) << (index * 7);
      if (next < 0x80) return value;
    }
    fail('Unterminated u32 LEB128 for $what');
  }

  BigInt u64(String what) {
    var value = BigInt.zero;
    for (var index = 0; index < 10; index++) {
      final next = byte(what);
      if (index == 9 && next > 1) fail('Overflowing u64 LEB128 for $what');
      value |= BigInt.from(next & 0x7f) << (index * 7);
      if (next < 0x80) return value;
    }
    fail('Unterminated u64 LEB128 for $what');
  }

  int s33(String what) {
    var value = 0;
    for (var index = 0; index < 5; index++) {
      final next = byte(what);
      final payload = next & 0x7f;
      if (index == 4 &&
          (next >= 0x80 ||
              (payload & 0x60) != ((payload & 0x10) == 0 ? 0 : 0x60))) {
        fail('Overflowing s33 LEB128 for $what');
      }
      value |= payload << (index * 7);
      if (next < 0x80) {
        if ((next & 0x40) != 0) value -= 1 << ((index + 1) * 7);
        return value;
      }
    }
    fail('Unterminated s33 LEB128 for $what');
  }

  String name(String what) {
    final length = u32('$what length');
    require(length, what);
    final start = offset;
    offset += length;
    try {
      return utf8.decode(Uint8List.sublistView(bytes, start, offset));
    } on FormatException {
      fail('Invalid UTF-8 $what');
    }
  }

  WasmImportKind importDescriptor() {
    final kind = byte('import kind');
    switch (kind) {
      case 0:
        u32('function type index');
        return WasmImportKind.function;
      case 1:
        referenceType();
        limits(sharedAllowed: false);
        return WasmImportKind.table;
      case 2:
        limits(sharedAllowed: true);
        return WasmImportKind.memory;
      case 3:
        valueType();
        if (byte('global mutability') > 1) fail('Invalid global mutability');
        return WasmImportKind.global;
      case 4:
        if (byte('tag attribute') != 0) fail('Unsupported tag attribute');
        u32('tag type index');
        return WasmImportKind.tag;
      default:
        fail('Unknown import kind $kind');
    }
  }

  void valueType() {
    require(1, 'global value type');
    if (bytes[offset] >= 0x7b && bytes[offset] <= 0x7f) {
      offset++;
    } else {
      referenceType();
    }
  }

  void referenceType() {
    final type = byte('reference type');
    if (type >= 0x69 && type <= 0x74) return;
    if (type != 0x63 && type != 0x64) fail('Invalid reference type $type');
    require(1, 'heap type');
    if (bytes[offset] >= 0x69 && bytes[offset] <= 0x74) {
      offset++;
    } else if (s33('heap type index') < 0) {
      fail('Invalid heap type index');
    }
  }

  void limits({required bool sharedAllowed}) {
    final flags = byte('limits flags');
    if ((flags & ~7) != 0 || (!sharedAllowed && (flags & 2) != 0)) {
      fail('Unsupported limits flags $flags');
    }
    if ((flags & 2) != 0 && (flags & 1) == 0) {
      fail('Shared memory requires a maximum');
    }
    final minimum = u64('minimum limit');
    final maximum = (flags & 1) == 0 ? null : u64('maximum limit');
    if ((flags & 4) == 0 &&
        (minimum > BigInt.from(0xffffffff) ||
            (maximum != null && maximum > BigInt.from(0xffffffff)))) {
      fail('Wasm32 limits exceed 32 bits');
    }
    if (maximum != null && minimum > maximum) {
      fail('Minimum limit exceeds maximum');
    }
  }
}
