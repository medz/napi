import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const _page = 0x4000;
const _segment64 = 0x19;
const _symtab = 0x2;
const _dysymtab = 0xb;
const _codeSignature = 0x1d;
const _exportsTrie = 0x80000033;
const _chainedFixups = 0x80000034;

int _align(int value, int alignment) => (value + alignment - 1) & -alignment;

final class _Command {
  _Command(this.bytes);

  final Uint8List bytes;
  ByteData get view => ByteData.sublistView(bytes);
  int get kind => u32(0);
  int u32(int offset) => view.getUint32(offset, Endian.little);
  int u64(int offset) => view.getUint64(offset, Endian.little);
  void set32(int offset, int value) =>
      view.setUint32(offset, value, Endian.little);
  void set64(int offset, int value) =>
      view.setUint64(offset, value, Endian.little);
  String get name => _string(bytes, 8);
}

final class _Segment {
  _Segment(this.name, this.bytes, this.address, this.size, this.protections);

  final String name;
  final Uint8List bytes;
  final int address;
  final int size;
  final int protections;
}

String _string(Uint8List bytes, int offset) {
  final end = bytes.indexOf(0, offset);
  if (end < 0) throw FormatException('Unterminated Mach-O string at $offset');
  return utf8.decode(bytes.sublist(offset, end));
}

int _uleb(Uint8List bytes, List<int> cursor) {
  var value = 0;
  var shift = 0;
  while (true) {
    final byte = bytes[cursor[0]++];
    value |= (byte & 0x7f) << shift;
    if (byte < 0x80) return value;
    shift += 7;
    if (shift >= 64) throw const FormatException('Oversized ULEB128');
  }
}

List<int> _encodeUleb(int value) {
  final result = <int>[];
  do {
    final byte = value & 0x7f;
    value = value >>> 7;
    result.add(value == 0 ? byte : byte | 0x80);
  } while (value != 0);
  return result;
}

/// Repackages the pinned SDK's arm64 runtime without assembling or linking it.
/// Runtime code/data retain their addresses; dyld still applies their fixups.
final class MachOImage {
  MachOImage.parse(Uint8List bytes) : _bytes = Uint8List.fromList(bytes) {
    final header = ByteData.sublistView(_bytes);
    if (header.getUint32(0, Endian.little) != 0xfeedfacf ||
        header.getUint32(4, Endian.little) != 0x0100000c ||
        header.getUint32(12, Endian.little) != 2) {
      throw const FormatException('Expected an arm64 Mach-O executable');
    }
    // dyld keeps images with static thread-local storage loaded. The VM and
    // I/O threads outlive individual Node environments, including Workers.
    if (header.getUint32(24, Endian.little) & 0x800000 == 0) {
      throw const FormatException('Runtime must retain its TLS descriptors');
    }
    final count = header.getUint32(16, Endian.little);
    _headerLimit = 32 + header.getUint32(20, Endian.little);
    var offset = 32;
    for (var i = 0; i < count; ++i) {
      final size = header.getUint32(offset + 4, Endian.little);
      if (size < 8 || offset + size > _headerLimit) {
        throw const FormatException('Invalid Mach-O load command');
      }
      _commands.add(
        _Command(Uint8List.fromList(_bytes.sublist(offset, offset + size))),
      );
      offset += size;
    }
    if (offset != _headerLimit) {
      throw const FormatException('Invalid command size');
    }
    final segments = _commands.where((command) => command.kind == _segment64);
    final text = segments.singleWhere((command) => command.name == '__TEXT');
    _linkedit = segments.singleWhere((command) => command.name == '__LINKEDIT');
    imageBase = text.u64(24);
    _nextVmAddress = _linkedit.u64(24);
    if (text.u64(40) != 0) {
      throw const FormatException('Expected mapped Mach-O header');
    }
    // The original header occupies no executable instructions. Removed commands
    // leave room for the two payload segments without moving runtime text.
    _readExports();
    _readImports();
  }

  final Uint8List _bytes;
  final _commands = <_Command>[];
  final _segments = <_Segment>[];
  final _exports = <String, Uint8List>{};
  final _imports = <String, int>{};
  late final _Command _linkedit;
  late final int _headerLimit;
  late final int imageBase;
  late int _nextVmAddress;

  int get nextVmAddress => _nextVmAddress;

  int symbolAddress(String name) {
    final terminal = _exports[name];
    if (terminal == null) throw ArgumentError('Runtime does not export $name');
    final cursor = [0];
    final flags = _uleb(terminal, cursor);
    if (flags & 0x18 != 0 || flags & 3 == 1) {
      throw UnsupportedError('Unsupported export kind for $name');
    }
    final address = _uleb(terminal, cursor);
    return flags & 3 == 2 ? address : imageBase + address;
  }

  /// Address of an existing pointer slot that dyld binds before module entry.
  int importPointerAddress(String name) =>
      _imports[name] ?? (throw ArgumentError('Runtime does not import $name'));

  int addSegment(
    String name,
    Uint8List bytes, {
    required int vmSize,
    required int protections,
  }) {
    if (ascii.encode(name).length > 16 ||
        vmSize < bytes.length ||
        vmSize <= 0) {
      throw ArgumentError('Invalid segment $name');
    }
    if (_segments.any((segment) => segment.name == name) ||
        _commands.any(
          (command) => command.kind == _segment64 && command.name == name,
        )) {
      throw ArgumentError('Duplicate segment $name');
    }
    final address = _nextVmAddress;
    final size = _align(vmSize, _page);
    _segments.add(
      _Segment(name, Uint8List.fromList(bytes), address, size, protections),
    );
    _nextVmAddress += size;
    return address;
  }

  void addExport(String name, int vmAddress) {
    if (vmAddress < imageBase || _exports.containsKey(name)) {
      throw ArgumentError('Invalid or duplicate export $name');
    }
    _exports[name] = Uint8List.fromList([
      0,
      ..._encodeUleb(vmAddress - imageBase),
    ]);
  }

  _Command _command(int kind) =>
      _commands.singleWhere((command) => command.kind == kind);

  Uint8List _commandData(int kind) {
    final command = _command(kind);
    return Uint8List.sublistView(
      _bytes,
      command.u32(8),
      command.u32(8) + command.u32(12),
    );
  }

  void _readExports() {
    final trie = _commandData(_exportsTrie);
    void visit(int offset, String prefix, Set<int> parents) {
      if (!parents.add(offset)) {
        throw const FormatException('Cyclic export trie');
      }
      final cursor = [offset];
      final terminalSize = _uleb(trie, cursor);
      if (terminalSize != 0) {
        _exports[prefix] = Uint8List.fromList(
          trie.sublist(cursor[0], cursor[0] + terminalSize),
        );
      }
      cursor[0] += terminalSize;
      final children = trie[cursor[0]++];
      for (var i = 0; i < children; ++i) {
        final label = _string(trie, cursor[0]);
        cursor[0] += utf8.encode(label).length + 1;
        final child = _uleb(trie, cursor);
        visit(child, '$prefix$label', Set.of(parents));
      }
    }

    visit(0, '', {});
  }

  void _readImports() {
    final fixups = _commandData(_chainedFixups);
    final data = ByteData.sublistView(fixups);
    final starts = data.getUint32(4, Endian.little);
    final imports = data.getUint32(8, Endian.little);
    final strings = data.getUint32(12, Endian.little);
    final count = data.getUint32(16, Endian.little);
    if (data.getUint32(20, Endian.little) != 1 ||
        data.getUint32(24, Endian.little) != 0) {
      throw const FormatException('Expected uncompressed DYLD_CHAINED_IMPORT');
    }
    final names = [
      for (var i = 0; i < count; ++i)
        _string(
          fixups,
          strings + (data.getUint32(imports + i * 4, Endian.little) >>> 9),
        ),
    ];
    final segments = _commands
        .where((command) => command.kind == _segment64)
        .toList();
    final segmentCount = data.getUint32(starts, Endian.little);
    if (segmentCount != segments.length) {
      throw const FormatException('Fixup segment count mismatch');
    }
    final image = ByteData.sublistView(_bytes);
    for (var index = 0; index < segmentCount; ++index) {
      final relative = data.getUint32(starts + 4 + index * 4, Endian.little);
      if (relative == 0) continue;
      final offset = starts + relative;
      final pageSize = data.getUint16(offset + 4, Endian.little);
      final format = data.getUint16(offset + 6, Endian.little);
      if (format != 2 && format != 6) {
        throw FormatException('Unsupported pointer format $format');
      }
      final pages = data.getUint16(offset + 20, Endian.little);
      final segment = segments[index];
      for (var page = 0; page < pages; ++page) {
        final start = data.getUint16(offset + 22 + page * 2, Endian.little);
        if (start == 0xffff) continue;
        final pageStarts = <int>[];
        if (start & 0x8000 == 0) {
          pageStarts.add(start);
        } else {
          var overflow = start & 0x7fff;
          while (true) {
            final entry = data.getUint16(
              offset + 22 + overflow++ * 2,
              Endian.little,
            );
            pageStarts.add(entry & 0x7fff);
            if (entry & 0x8000 != 0) break;
          }
        }
        for (final first in pageStarts) {
          var position = first;
          while (true) {
            if (position + 8 > pageSize) {
              throw const FormatException('Fixup leaves its page');
            }
            final local = page * pageSize + position;
            final pointer = image.getUint64(
              segment.u64(40) + local,
              Endian.little,
            );
            if (pointer >>> 63 != 0) {
              final name = names[pointer & 0xffffff];
              _imports.putIfAbsent(name, () => segment.u64(24) + local);
            }
            final next = (pointer >>> 51) & 0xfff;
            if (next == 0) break;
            position += next * 4;
          }
        }
      }
    }
  }

  Uint8List _rebuildFixups(List<_Command> segments) {
    final old = _commandData(_chainedFixups);
    final data = ByteData.sublistView(old);
    final oldStarts = data.getUint32(4, Endian.little);
    final originalSegments = _commands
        .where((command) => command.kind == _segment64)
        .toList();
    final records = <Uint8List?>[];
    for (final segment in segments) {
      final index = originalSegments.indexWhere(
        (original) => original.name == segment.name,
      );
      if (index < 0) {
        records.add(null);
        continue;
      }
      final relative = data.getUint32(oldStarts + 4 + index * 4, Endian.little);
      if (relative == 0) {
        records.add(null);
        continue;
      }
      final offset = oldStarts + relative;
      final size = data.getUint32(offset, Endian.little);
      final record = Uint8List.fromList(old.sublist(offset, offset + size));
      ByteData.sublistView(record)
          .setUint64(8, segment.u64(24) - imageBase, Endian.little);
      records.add(record);
    }
    var startsSize = _align(4 + records.length * 4, 8);
    final locations = <int>[];
    for (final record in records) {
      locations.add(record == null ? 0 : startsSize);
      if (record != null) startsSize = _align(startsSize + record.length, 8);
    }
    final oldImports = data.getUint32(8, Endian.little);
    final oldStrings = data.getUint32(12, Endian.little);
    final importsSize = data.getUint32(16, Endian.little) * 4;
    const starts = 32;
    final imports = starts + startsSize;
    final strings = imports + importsSize;
    final result = Uint8List(strings + old.length - oldStrings);
    result.setRange(0, 28, old);
    final view = ByteData.sublistView(result);
    view.setUint32(4, starts, Endian.little);
    view.setUint32(8, imports, Endian.little);
    view.setUint32(12, strings, Endian.little);
    view.setUint32(starts, records.length, Endian.little);
    for (var i = 0; i < records.length; ++i) {
      view.setUint32(starts + 4 + i * 4, locations[i], Endian.little);
      final record = records[i];
      if (record != null) {
        result.setRange(
          starts + locations[i],
          starts + locations[i] + record.length,
          record,
        );
      }
    }
    result.setRange(imports, strings, old, oldImports);
    result.setRange(strings, result.length, old, oldStrings);
    return result;
  }

  Uint8List build({String identifier = 'napi.native-image'}) {
    // All SDK dependencies are absolute system libraries; no rpath is needed.
    for (final command in _commands.where((command) => command.kind == 0xc)) {
      if (!_string(command.bytes, command.u32(8)).startsWith('/')) {
        throw const FormatException(
          'Cannot discard runtime rpaths with relative dependencies',
        );
      }
    }
    final commands = <_Command>[];
    for (final original in _commands) {
      if (original.kind == _segment64 &&
          (original.name == '__PAGEZERO' ||
              original.name == '__LINKEDIT' ||
              original.name == '__CUSTOM' && original.u64(32) == 0)) {
        continue;
      }
      if ({0x80000028, 0xe, 0x8000001c}.contains(original.kind)) continue;
      commands.add(_Command(Uint8List.fromList(original.bytes)));
    }
    final output = BytesBuilder(copy: false)
      ..add(_bytes.sublist(0, _linkedit.u64(40)));
    for (final segment in _segments) {
      output.add(Uint8List(_align(output.length, _page) - output.length));
      commands.add(
        _makeSegment(
          segment.name,
          segment.address,
          segment.size,
          output.length,
          segment.bytes.length,
          segment.protections,
        ),
      );
      output.add(segment.bytes);
    }
    output.add(Uint8List(_align(output.length, _page) - output.length));
    final linkOffset = output.length;
    final oldLinkOffset = _linkedit.u64(40);
    final oldSignature = _command(_codeSignature).u32(8);
    if (oldSignature < oldLinkOffset) {
      throw const FormatException('Signature precedes linkedit');
    }
    output.add(_bytes.sublist(oldLinkOffset, oldSignature));
    final linkedit = _makeSegment(
      '__LINKEDIT',
      _nextVmAddress,
      0,
      linkOffset,
      0,
      1,
    );
    commands.add(linkedit);
    final delta = linkOffset - oldLinkOffset;
    for (final command in commands) {
      if (command.kind == _symtab) {
        command.set32(8, command.u32(8) + delta);
        command.set32(16, command.u32(16) + delta);
      } else if (command.kind == _dysymtab) {
        for (final field in [32, 40, 48, 56, 64, 72]) {
          if (command.u32(field) != 0) {
            command.set32(field, command.u32(field) + delta);
          }
        }
      } else if ({0x26, 0x29}.contains(command.kind) && command.u32(8) != 0) {
        command.set32(8, command.u32(8) + delta);
      }
    }
    void replaceData(int kind, Uint8List bytes) {
      output.add(Uint8List(_align(output.length, 8) - output.length));
      final command = commands.singleWhere((command) => command.kind == kind);
      command.set32(8, output.length);
      command.set32(12, bytes.length);
      output.add(bytes);
    }

    replaceData(
      _chainedFixups,
      _rebuildFixups(
        commands.where((command) => command.kind == _segment64).toList(),
      ),
    );
    replaceData(_exportsTrie, _writeTrie(_exports));
    output.add(Uint8List(_align(output.length, 16) - output.length));
    final codeLimit = output.length;
    final signatureSize = _signatureSize(identifier, codeLimit);
    final signature = commands.singleWhere(
      (command) => command.kind == _codeSignature,
    );
    signature.set32(8, codeLimit);
    signature.set32(12, signatureSize);
    linkedit.set64(32, _align(codeLimit + signatureSize - linkOffset, _page));
    linkedit.set64(48, codeLimit + signatureSize - linkOffset);
    final commandSize = commands.fold<int>(
      0,
      (size, command) => size + command.bytes.length,
    );
    if (32 + commandSize > _headerLimit) {
      throw StateError('New segment commands exceed the original header space');
    }
    final image = output.takeBytes();
    image.fillRange(32, _headerLimit, 0);
    final header = ByteData.sublistView(image);
    header.setUint32(12, 8, Endian.little); // MH_BUNDLE
    header.setUint32(16, commands.length, Endian.little);
    header.setUint32(20, commandSize, Endian.little);
    header.setUint32(
      24,
      header.getUint32(24, Endian.little) & ~0x200000,
      Endian.little,
    ); // MH_PIE
    var offset = 32;
    for (final command in commands) {
      image.setRange(offset, offset + command.bytes.length, command.bytes);
      offset += command.bytes.length;
    }
    final text = commands.firstWhere(
      (command) => command.kind == _segment64 && command.name == '__TEXT',
    );
    return (BytesBuilder(copy: false)
          ..add(image)
          ..add(_sign(image, identifier, text.u64(40), text.u64(48))))
        .takeBytes();
  }
}

_Command _makeSegment(
  String name,
  int address,
  int size,
  int offset,
  int length,
  int protections,
) {
  final command = _Command(Uint8List(72));
  command.set32(0, _segment64);
  command.set32(4, 72);
  command.bytes.setRange(8, 8 + ascii.encode(name).length, ascii.encode(name));
  command.set64(24, address);
  command.set64(32, size);
  command.set64(40, offset);
  command.set64(48, length);
  command.set32(56, protections);
  command.set32(60, protections);
  return command;
}

final class _TrieNode {
  Uint8List terminal = Uint8List(0);
  final children = <String, _TrieNode>{};
  int offset = 0;
}

Uint8List _writeTrie(Map<String, Uint8List> exports) {
  final root = _TrieNode();
  for (final name in exports.keys.toList()..sort()) {
    var node = root;
    for (final code in name.codeUnits) {
      node = node.children.putIfAbsent(
        String.fromCharCode(code),
        _TrieNode.new,
      );
    }
    node.terminal = exports[name]!;
  }
  final nodes = <_TrieNode>[];
  void compress(_TrieNode node) {
    final children = <String, _TrieNode>{};
    for (final entry in node.children.entries) {
      var label = entry.key;
      var child = entry.value;
      while (child.terminal.isEmpty && child.children.length == 1) {
        final next = child.children.entries.single;
        label += next.key;
        child = next.value;
      }
      children[label] = child;
    }
    node.children.clear();
    node.children.addAll(children);
    nodes.add(node);
    for (final child in children.values) {
      compress(child);
    }
  }

  compress(root);
  Uint8List encode(_TrieNode node) => Uint8List.fromList([
    ..._encodeUleb(node.terminal.length),
    ...node.terminal,
    node.children.length,
    for (final entry in node.children.entries) ...[
      ...utf8.encode(entry.key),
      0,
      ..._encodeUleb(entry.value.offset),
    ],
  ]);
  for (var pass = 0; pass < 16; ++pass) {
    var offset = 0;
    var changed = false;
    for (final node in nodes) {
      if (node.offset != offset) changed = true;
      node.offset = offset;
      offset += encode(node).length;
    }
    if (!changed) {
      final output = BytesBuilder(copy: false);
      for (final node in nodes) {
        output.add(encode(node));
      }
      return output.takeBytes();
    }
  }
  throw StateError('Export trie layout did not converge');
}

int _signatureSize(String identifier, int codeLimit) => _align(
  20 +
      88 +
      utf8.encode(identifier).length +
      1 +
      ((codeLimit + 4095) ~/ 4096) * 32,
  16,
);

Uint8List _sign(
  Uint8List image,
  String identifier,
  int executableOffset,
  int executableSize,
) {
  final name = utf8.encode(identifier);
  final slots = (image.length + 4095) ~/ 4096;
  final hashOffset = 88 + name.length + 1;
  final directorySize = hashOffset + slots * 32;
  final bytes = Uint8List(_signatureSize(identifier, image.length));
  final data = ByteData.sublistView(bytes);
  void word(int offset, int value) => data.setUint32(offset, value, Endian.big);
  word(0, 0xfade0cc0); // Embedded signature superblob.
  word(4, 20 + directorySize);
  word(8, 1);
  word(12, 0);
  word(16, 20);
  const cd = 20;
  word(cd, 0xfade0c02);
  word(cd + 4, directorySize);
  word(cd + 8, 0x20400);
  word(cd + 12, 2); // CS_ADHOC
  word(cd + 16, hashOffset);
  word(cd + 20, 88);
  word(cd + 24, 0);
  word(cd + 28, slots);
  word(cd + 32, image.length);
  bytes[cd + 36] = 32;
  bytes[cd + 37] = 2; // SHA-256
  bytes[cd + 39] = 12; // 4096-byte signing pages.
  data.setUint64(cd + 64, executableOffset, Endian.big);
  data.setUint64(cd + 72, executableSize, Endian.big);
  bytes.setRange(cd + 88, cd + 88 + name.length, name);
  for (var slot = 0; slot < slots; ++slot) {
    final start = slot * 4096;
    final end = start + 4096 < image.length ? start + 4096 : image.length;
    final digest = sha256
        .convert(Uint8List.sublistView(image, start, end))
        .bytes;
    bytes.setRange(
      cd + hashOffset + slot * 32,
      cd + hashOffset + (slot + 1) * 32,
      digest,
    );
  }
  return bytes;
}
