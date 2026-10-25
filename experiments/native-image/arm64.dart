import 'dart:typed_data';

/// The small AAPCS64 instruction subset used before a Dart isolate exists.
final class Arm64 {
  Arm64(this.base);

  final int base;
  final _words = <int>[];
  final _labels = <String, int>{};
  final _branches = <(int, String, int)>[];
  int get address => base + _words.length * 4;

  void word(int value) => _words.add(value);
  void label(String name) => _labels[name] = address;
  void mov(int to, int from) => word(0xaa0003e0 | (from << 16) | to);
  void immediate(int register, int value) {
    word(0xd2800000 | ((value & 0xffff) << 5) | register);
    for (var shift = 16; shift < 64; shift += 16) {
      final bits = (value >>> shift) & 0xffff;
      if (bits != 0) {
        word(0xf2800000 | ((shift ~/ 16) << 21) | (bits << 5) | register);
      }
    }
  }

  void add(int to, int from, int value) {
    if (value < 0 || value >= 4096) throw RangeError('ADD immediate');
    word(0x91000000 | (value << 10) | (from << 5) | to);
  }

  void subtract(int to, int from, int value) {
    if (value < 0 || value >= 4096) throw RangeError('SUB immediate');
    word(0xd1000000 | (value << 10) | (from << 5) | to);
  }

  void pointer(int register, int target) {
    final pages = ((target & ~4095) - (address & ~4095)) >> 12;
    if (pages < -(1 << 20) || pages >= 1 << 20) {
      throw RangeError('ADRP target');
    }
    final immediate = pages & 0x1fffff;
    word(
      0x90000000 | ((immediate & 3) << 29) | ((immediate >> 2) << 5) | register,
    );
    add(register, register, target & 4095);
  }

  void load(int register, int baseRegister, [int offset = 0]) =>
      word(0xf9400000 | ((offset ~/ 8) << 10) | (baseRegister << 5) | register);
  void store(int register, int baseRegister, [int offset = 0]) =>
      word(0xf9000000 | ((offset ~/ 8) << 10) | (baseRegister << 5) | register);

  void call(int target) {
    final delta = target - address;
    if (delta % 4 != 0 || delta < -(1 << 27) || delta >= 1 << 27) {
      throw RangeError('BL target');
    }
    word(0x94000000 | ((delta >> 2) & 0x3ffffff));
  }

  void indirect(int register) => word(0xd63f0000 | (register << 5));
  void imported(int slot) {
    pointer(16, slot);
    load(16, 16);
    indirect(16);
  }

  void branch(String label) {
    _branches.add((_words.length, label, 0x14000000));
    word(0);
  }

  void nonzero(int register, String label) {
    _branches.add((_words.length, label, 0xb5000000 | register));
    word(0);
  }

  void zero(int register, String label) {
    _branches.add((_words.length, label, 0xb4000000 | register));
    word(0);
  }

  void enter() {
    subtract(31, 31, 256);
    for (var register = 19; register <= 24; ++register) {
      store(register, 31, 192 + (register - 19) * 8);
    }
    store(29, 31, 240);
    store(30, 31, 248);
    add(29, 31, 240);
  }

  void leave() {
    for (var register = 19; register <= 24; ++register) {
      load(register, 31, 192 + (register - 19) * 8);
    }
    load(29, 31, 240);
    load(30, 31, 248);
    add(31, 31, 256);
    word(0xd65f03c0);
  }

  Uint8List finish() {
    final bytes = Uint8List(_words.length * 4);
    final data = ByteData.sublistView(bytes);
    for (final (offset, label, opcode) in _branches) {
      final delta = (_labels[label]! - (base + offset * 4)) >> 2;
      _words[offset] = opcode == 0x14000000
          ? opcode | (delta & 0x3ffffff)
          : opcode | ((delta & 0x7ffff) << 5);
    }
    for (var i = 0; i < _words.length; ++i) {
      data.setUint32(i * 4, _words[i], Endian.little);
    }
    return bytes;
  }
}
