import 'dart:convert';
import 'dart:typed_data';

import '../sdk_adapter/host_template.dart';

final class WasmLinkException implements Exception {
  const WasmLinkException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

final class LinkedDartModule {
  const LinkedDartModule({
    required this.wasmBytes,
    required this.hostJavaScript,
  });

  final Uint8List wasmBytes;
  final String hostJavaScript;
}

/// Makes the compiler's import section resolve through native Node Wasm ESM.
///
/// Every other section, including start, exports, and custom/debug sections,
/// stays byte-for-byte unchanged. No business `main` call is added. The host's
/// import cycle is safe because its top level never reads a core Wasm export.
LinkedDartModule linkDartModule({
  required List<int> rawWasmBytes,
  required String rawMjsText,
  required String hostSpecifier,
  required String coreSpecifier,
  Map<String, String> additionalImports = const {},
}) {
  _checkSpecifier(hostSpecifier);
  _checkSpecifier(coreSpecifier);
  for (final entry in additionalImports.entries) {
    if (_compilerModules.contains(entry.key)) {
      throw ArgumentError('Cannot override compiler import ${entry.key}.');
    }
    _checkSpecifier(entry.value);
  }
  final helpers = extractDartHostHelpers(rawMjsText);
  final input = _Reader(rawWasmBytes);
  _readHeader(input);
  final output = BytesBuilder(copy: false)..add(_header);
  final host = StringBuffer()
    ..writeln('// Generated private Dart SDK host dependency. SDK: 3.13.5.')
    ..writeln('import * as coreExports from ${jsonEncode(coreSpecifier)};')
    ..writeln('const dartInstance = {exports: coreExports};')
    ..write(helpers);
  var importSectionSeen = false;
  var aliasIndex = 0;

  while (!input.atEnd) {
    final sectionStart = input.offset;
    final id = input.byte();
    final size = input.u32();
    final sectionEnd = input.offset + size;
    input.require(size);
    if (id != 2) {
      output.add(input.bytes.sublist(sectionStart, sectionEnd));
      input.offset = sectionEnd;
      continue;
    }
    if (importSectionSeen) _malformed('Duplicate import section.');
    importSectionSeen = true;
    final section = _Reader(input.bytes.sublist(input.offset, sectionEnd));
    input.offset = sectionEnd;
    final count = section.u32();
    final rewritten = BytesBuilder(copy: false)..add(_u32(count));
    for (var index = 0; index < count; index++) {
      final module = section.name();
      final name = section.name();
      final descriptorStart = section.offset;
      final kind = section.byte();
      switch (kind) {
        case 0: // Function import: type index.
          section.u32();
        case 3: // Global import: value type and mutability.
          section.valueType();
          final mutability = section.byte();
          if (mutability > 1) _malformed('Invalid global mutability.');
        case 4: // Exception tag: attribute and function type index.
          if (section.byte() != 0) _malformed('Invalid exception tag.');
          section.u32();
        default:
          throw WasmLinkException(
            'NAPI_WASM_IMPORT_KIND',
            'Unsupported import kind $kind for $module.$name. '
                'Shared memories and imported tables are not supported.',
          );
      }
      final descriptor = section.bytes.sublist(descriptorStart, section.offset);
      var targetModule = module;
      var targetName = name;
      if (additionalImports.containsKey(module)) {
        targetModule = additionalImports[module]!;
      } else if (module == 'wasm:js-string') {
        if (kind != 0 || !_jsStringBuiltins.contains(name)) {
          _unknownImport(module, name);
        }
        // Node provides these as compile-time Wasm builtins.
      } else {
        String expression;
        if (module.isEmpty) {
          if (!_isImmutableExternref(descriptor)) {
            _unknownImport(module, name);
          }
          expression = jsonEncode(name);
        } else if (module == 'dart2wasm') {
          if (kind != 0) _unknownImport(module, name);
          verifyDartHostImport(helpers, name);
          expression = 'dart2wasm[${jsonEncode(name)}]';
        } else if (module == 'WebAssembly') {
          if (kind != 4 || name != 'JSTag') _unknownImport(module, name);
          expression = 'WebAssembly.JSTag';
        } else if (_standardModules.contains(module) && kind == 0) {
          expression = '$module[${jsonEncode(name)}]';
        } else {
          _unknownImport(module, name);
        }
        targetModule = hostSpecifier;
        targetName = '_napiHost${aliasIndex++}';
        host.writeln('const $targetName = $expression;');
        if (kind == 0) {
          host.writeln(
            'if (typeof $targetName !== "function") '
            'throw new Error(${jsonEncode('NAPI_SDK_HOST_IMPORT: Missing '
            '$module.$name in Dart 3.13.5 host module.')});',
          );
        }
        host.writeln('export {$targetName};');
      }
      rewritten
        ..add(_name(targetModule))
        ..add(_name(targetName))
        ..add(descriptor);
    }
    if (!section.atEnd) _malformed('Trailing bytes in import section.');
    final payload = rewritten.takeBytes();
    output
      ..addByte(2)
      ..add(_u32(payload.length))
      ..add(payload);
  }
  if (!importSectionSeen) {
    _malformed('Expected the pinned Dart compiler import section.');
  }
  return LinkedDartModule(
    wasmBytes: output.takeBytes(),
    hostJavaScript: host.toString(),
  );
}

/// A public Wasm module whose immutable externref exports are real JS values.
///
/// Node's native Wasm ESM loader unwraps immutable globals. A constructor or
/// argument-preserving function can therefore stay directly importable from
/// `.wasm` while its host dependency calls the linked Dart core. This separate
/// facade never shifts any of the core module's global indices.
Uint8List buildPublicWasmFacade({
  required String hostSpecifier,
  required List<String> exportNames,
}) {
  _checkSpecifier(hostSpecifier);
  if (exportNames.toSet().length != exportNames.length ||
      exportNames.any((name) => name.isEmpty)) {
    throw ArgumentError('Facade export names must be nonempty and unique.');
  }
  for (final name in exportNames) {
    if (name == 'then' ||
        name.startsWith('wasm:') ||
        name.startsWith('wasm-js:')) {
      throw WasmLinkException(
        'NAPI_WASM_EXPORT_NAME',
        'Export ${jsonEncode(name)} is unsafe for native Wasm ESM: '
            '"then" can trigger Promise assimilation, and "wasm:" / '
            '"wasm-js:" are reserved Node prefixes.',
      );
    }
  }
  final imports = BytesBuilder(copy: false)..add(_u32(exportNames.length));
  final exports = BytesBuilder(copy: false)..add(_u32(exportNames.length));
  for (var index = 0; index < exportNames.length; index++) {
    imports
      ..add(_name(hostSpecifier))
      ..add(_name(exportNames[index]))
      ..add(const [3, 0x6f, 0]); // Immutable nullable externref global.
    exports
      ..add(_name(exportNames[index]))
      ..addByte(3)
      ..add(_u32(index));
  }
  final output = BytesBuilder(copy: false)..add(_header);
  for (final section in [(2, imports.takeBytes()), (7, exports.takeBytes())]) {
    output
      ..addByte(section.$1)
      ..add(_u32(section.$2.length))
      ..add(section.$2);
  }
  return output.takeBytes();
}

const _header = [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0];
const _standardModules = {'Math', 'Date', 'Object', 'Array', 'Reflect'};
const _compilerModules = {
  '',
  'dart2wasm',
  'wasm:js-string',
  'WebAssembly',
  ..._standardModules,
};
const _jsStringBuiltins = {
  'cast',
  'test',
  'charCodeAt',
  'codePointAt',
  'compare',
  'concat',
  'equals',
  'fromCharCode',
  'fromCodePoint',
  'length',
  'substring',
  'fromCharCodeArray',
  'intoCharCodeArray',
};

bool _isImmutableExternref(List<int> descriptor) =>
    (descriptor.length == 3 && descriptor[1] == 0x6f && descriptor[2] == 0) ||
    (descriptor.length == 4 &&
        (descriptor[1] == 0x63 || descriptor[1] == 0x64) &&
        descriptor[2] == 0x6f &&
        descriptor[3] == 0);

void _checkSpecifier(String value) {
  if (!(value.startsWith('./') || value.startsWith('../')) ||
      value.contains('\u0000') ||
      value.contains(r'\') ||
      value.contains('?') ||
      value.contains('#')) {
    throw ArgumentError.value(
      value,
      'specifier',
      'Generated dependencies require plain relative ESM specifiers.',
    );
  }
}

void _readHeader(_Reader input) {
  for (final byte in _header) {
    if (input.byte() != byte) _malformed('Invalid Wasm v1 header.');
  }
}

List<int> _u32(int value) {
  final bytes = <int>[];
  do {
    var byte = value & 0x7f;
    value >>= 7;
    if (value != 0) byte |= 0x80;
    bytes.add(byte);
  } while (value != 0);
  return bytes;
}

List<int> _name(String value) {
  final bytes = utf8.encode(value);
  return [..._u32(bytes.length), ...bytes];
}

Never _unknownImport(String module, String name) => throw WasmLinkException(
  'NAPI_WASM_IMPORT',
  'Unsupported compiler import ${jsonEncode(module)}.${jsonEncode(name)}. '
      'Refusing to guess a host binding.',
);

Never _malformed(String detail) =>
    throw WasmLinkException('NAPI_WASM_FORMAT', detail);

final class _Reader {
  _Reader(List<int> input) : bytes = Uint8List.fromList(input) {
    if (input.any((byte) => byte < 0 || byte > 255)) {
      _malformed('Wasm bytes must be in the range 0 through 255.');
    }
  }

  final Uint8List bytes;
  int offset = 0;
  bool get atEnd => offset == bytes.length;

  void require(int count) {
    if (count < 0 || count > bytes.length - offset) {
      _malformed('Truncated Wasm data at byte $offset.');
    }
  }

  int byte() {
    require(1);
    return bytes[offset++];
  }

  int u32() {
    var result = 0;
    for (var index = 0; index < 5; index++) {
      final next = byte();
      if (index == 4 && next > 0x0f) _malformed('Invalid u32 LEB128.');
      result |= (next & 0x7f) << (7 * index);
      if (next < 0x80) return result;
    }
    _malformed('Invalid u32 LEB128.');
  }

  String name() {
    final length = u32();
    require(length);
    final start = offset;
    offset += length;
    try {
      return utf8.decode(bytes.sublist(start, offset));
    } on FormatException {
      _malformed('Invalid UTF-8 import name.');
    }
  }

  void valueType() {
    final type = byte();
    if (type == 0x63 || type == 0x64) {
      // A typed (nullable/non-nullable) reference has a signed heap type.
      for (var index = 0; index < 5; index++) {
        final next = byte();
        if (index == 4 && (next & 0xf0) != 0 && (next & 0xf0) != 0x70) {
          _malformed('Invalid signed heap type.');
        }
        if (next < 0x80) return;
      }
      _malformed('Invalid signed heap type.');
    }
    if (!(type >= 0x69 && type <= 0x74) && !(type >= 0x7b && type <= 0x7f)) {
      _malformed('Unknown global value type.');
    }
  }
}
