import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:napi/src/wasm.dart';
import 'package:test/test.dart';

const _header = [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0];

void main() {
  test('preserves every byte outside the import section', () {
    final before = [0, 0x81, 0, 0]; // Noncanonical section length.
    final gcTypes = _section(1, [1, 0x4e, 1, 0x5f, 0]);
    final after = _section(0, [0, 0xfe, 0xff]);
    final futureSection = _section(42, [7, 8, 9]);
    final source = Uint8List.fromList([
      ..._header,
      ...before,
      ...gcTypes,
      ..._section(
        2,
        _imports([
          ('env', 'add', [0, 0x80, 0]),
        ]),
      ),
      ...after,
      ...futureSection,
    ]);
    final result = rewriteImports(source);
    expect(result.bytes, [
      ..._header,
      ...before,
      ...gcTypes,
      ..._section(
        2,
        _imports([
          ('./module.imports.mjs', '_i0', [0, 0x80, 0]),
        ]),
      ),
      ...after,
      ...futureSection,
    ]);
    expect(source, isNot(same(result.bytes)));
  });

  test('leaves modules without an import section unchanged', () {
    final source = Uint8List.fromList([
      ..._header,
      ..._section(0, [0]),
    ]);
    final result = rewriteImports(source);
    expect(result.bytes, source);
    expect(result.imports, isEmpty);
  });

  test('keeps builtins and gives colliding host names unique aliases', () {
    final entries = <(String, String, List<int>)>[
      ('', 'hello', [3, 0x6f, 0]),
      ('wasm:js-string', 'length', [0, 0]),
      ('wasm:js/string-constants', 'world', [3, 0x6f, 0]),
      ('dart2wasm', 'same', [0, 0]),
      ('napi', 'same', [0, 0]),
      ('env', 'same', [0, 0]),
    ];
    final result = rewriteImports(
      _module(_imports(entries)),
      hostModule: './host.mjs',
    );
    expect(
      result.bytes,
      _module(
        _imports([
          ('wasm:js/string-constants', 'hello', [3, 0x6f, 0]),
          entries[1],
          entries[2],
          ('./host.mjs', '_i3', [0, 0]),
          ('./host.mjs', '_i4', [0, 0]),
          ('./host.mjs', '_i5', [0, 0]),
        ]),
      ),
    );
    expect(result.imports.map((entry) => entry.module), [
      'dart2wasm',
      'napi',
      'env',
    ]);
    expect(result.imports.map((entry) => entry.name), ['same', 'same', 'same']);
    expect(result.imports.map((entry) => entry.alias), ['_i3', '_i4', '_i5']);
    expect(
      result.imports.every((entry) => entry.kind == WasmImportKind.function),
      isTrue,
    );
    expect(() => result.imports.clear(), throwsUnsupportedError);
  });

  test('preserves all import descriptor kinds, GC references, and limits', () {
    final descriptors = <List<int>>[
      [0, 0x80, 0], // Function with a noncanonical type index.
      [1, 0x70, 0, 1], // funcref table.
      [1, 0x63, 0, 1, 1, 2], // Typed nullable reference table.
      [1, 0x64, 0x6b, 4, 1], // Non-null structref table64.
      [2, 0, 0], // Memory32.
      [2, 3, 1, 3], // Shared memory with a maximum.
      [2, 5, ..._unsigned(1 << 32), ..._unsigned((1 << 32) + 1)],
      [3, 0x7f, 1], // Mutable i32 global.
      [3, 0x6f, 0], // externref global.
      [3, 0x63, 0x80, 1, 0], // (ref null type 128) global.
      [3, 0x64, 0xff, 0xff, 0xff, 0xff, 0x0f, 0], // Largest type index.
      [4, 0, 0], // Exception tag.
    ];
    final entries = [
      for (var i = 0; i < descriptors.length; i++)
        ('env', 'item$i', descriptors[i]),
    ];
    final result = rewriteImports(_module(_imports(entries)));
    expect(
      result.bytes,
      _module(
        _imports([
          for (var i = 0; i < descriptors.length; i++)
            ('./module.imports.mjs', '_i$i', descriptors[i]),
        ]),
      ),
    );
    expect(result.imports.map((entry) => entry.kind), [
      WasmImportKind.function,
      WasmImportKind.table,
      WasmImportKind.table,
      WasmImportKind.table,
      WasmImportKind.memory,
      WasmImportKind.memory,
      WasmImportKind.memory,
      WasmImportKind.global,
      WasmImportKind.global,
      WasmImportKind.global,
      WasmImportKind.global,
      WasmImportKind.tag,
    ]);
  });

  test('accepts every standardized reference shorthand and numeric global', () {
    for (final type in [
      ...List.generate(12, (i) => 0x69 + i),
      0x7b,
      0x7c,
      0x7d,
      0x7e,
      0x7f,
    ]) {
      expect(
        rewriteImports(
          _module(
            _imports([
              ('env', 'g', [3, type, 0]),
            ]),
          ),
        ).imports.single.kind,
        WasmImportKind.global,
      );
    }
  });

  test('rejects malformed framing, counts, names, and duplicate sections', () {
    final malformed = <List<int>>[
      [],
      [0, 0x61, 0x73, 0x6d, 2, 0, 0, 0],
      [..._header, 2],
      [..._header, 2, 0x80],
      [..._header, 2, 0xff, 0xff, 0xff, 0xff, 0x10],
      [..._header, 2, 0x80, 0x80, 0x80, 0x80, 0x80, 0],
      [..._header, 2, 5, 0],
      [..._header, ..._section(2, [])],
      [
        ..._header,
        ..._section(2, [1]),
      ],
      [
        ..._header,
        ..._section(2, [0xff, 0xff, 0xff, 0xff, 0x0f]),
      ],
      [
        ..._header,
        ..._section(2, [1, 20, 0, 0, 0, 0]),
      ],
      [
        ..._header,
        ..._section(2, [1, 1, 0xff, 0, 0, 0]),
      ],
      [
        ..._header,
        ..._section(2, [0, 1]),
      ],
      [
        ..._header,
        ..._section(2, [0]),
        ..._section(2, [0]),
      ],
    ];
    for (final bytes in malformed) {
      expect(
        () => rewriteImports(Uint8List.fromList(bytes)),
        throwsFormatException,
        reason: '$bytes',
      );
    }
    expect(
      () => rewriteImports(Uint8List.fromList(_header), hostModule: ''),
      throwsArgumentError,
    );
    expect(
      () => rewriteImports(
        _module(
          _imports([
            ('', 'f', [0, 0]),
          ]),
        ),
      ),
      throwsFormatException,
    );
  });

  test('rejects malformed descriptors with a useful byte offset', () {
    final malformed = <List<int>>[
      [5, 0],
      [0, 0xff, 0xff, 0xff, 0xff, 0x10],
      [1, 0x7f, 0, 0],
      [1, 0x70, 3, 0, 1],
      [2, 8, 0],
      [2, 2, 0],
      [2, 1, 2, 1],
      [2, 0, ..._unsigned(1 << 32)],
      [2, 4, ...List.filled(9, 0x80), 2],
      [2, 4, ...List.filled(10, 0x80), 0],
      [3, 0x68, 0],
      [3, 0x7f, 2],
      [3, 0x63, 0x7f, 0],
      [3, 0x63, 0x80, 0x80, 0x80, 0x80, 0x20, 0],
      [3, 0x63, 0x80, 0x80, 0x80, 0x80, 0x80, 0, 0],
      [4, 1, 0],
      [4, 0],
    ];
    for (final descriptor in malformed) {
      expect(
        () => rewriteImports(_module(_imports([('env', 'bad', descriptor)]))),
        throwsA(
          isA<FormatException>()
              .having((error) => error.offset, 'offset', isNotNull)
              .having((error) => error.message, 'message', contains('byte')),
        ),
        reason: '$descriptor',
      );
    }
  });

  test('native Wasm ESM resolves names without a custom loader', () async {
    final directory = await Directory.systemTemp.createTemp('napi-wasm-esm-');
    addTearDown(() => directory.delete(recursive: true));
    final original = Uint8List.fromList([
      ..._header,
      ..._section(1, [1, 0x60, 2, 0x7f, 0x7f, 1, 0x7f]),
      ..._section(
        2,
        _imports([
          ('first', 'same', [0, 0]),
          ('second', 'same', [0, 0]),
        ]),
      ),
      ..._section(3, [1, 0]),
      ..._section(7, [1, ..._name('add'), 0, 2]),
      ..._section(10, [
        1,
        15,
        0,
        0x20,
        0,
        0x20,
        1,
        0x10,
        0,
        0x20,
        0,
        0x20,
        1,
        0x10,
        1,
        0x6a,
        0x0b,
      ]),
    ]);
    await File('${directory.path}/module.wasm')
        .writeAsBytes(rewriteImports(original).bytes);
    await File('${directory.path}/module.imports.mjs').writeAsString(
      'export const _i0 = (a, b) => a + b;\nexport const _i1 = (a, b) => a - b;\n',
    );
    await File('${directory.path}/main.mjs').writeAsString(
      "import { add } from './module.wasm';\nconsole.log(JSON.stringify([add(20, 22), add(7, 3)]));\n",
    );
    final result = await Process.run('node', [
      'main.mjs',
    ], workingDirectory: directory.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(jsonDecode((result.stdout as String).trim()), [40, 14]);
  });

  test(
    'rewrites a real Dart GC module and preserves its other sections',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'napi-wasm-dart-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/probe.dart');
      await source.writeAsString('''
import 'dart:_wasm';
@pragma('wasm:import', 'probe.touch')
external WasmI32 touch(WasmI32 value);
@pragma('wasm:export', 'add')
WasmI32 add(WasmI32 a, WasmI32 b) => touch(WasmI32.fromInt(a.toIntSigned() + b.toIntSigned()));
void main() { print('real Dart GC module'); }
''');
      final result = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'wasm',
        '-E--enable-experimental-wasm-interop',
        source.path,
        '-o',
        '${directory.path}/original.wasm',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      final original = await File('${directory.path}/original.wasm')
          .readAsBytes();
      final rewritten = rewriteImports(original);
      expect(_otherSections(rewritten.bytes), _otherSections(original));
      expect(
        rewritten.imports.any(
          (entry) => entry.module == 'probe' && entry.name == 'touch',
        ),
        isTrue,
      );
      await File('${directory.path}/rewritten.wasm')
          .writeAsBytes(rewritten.bytes);
      await File('${directory.path}/validate.mjs').writeAsString('''
import { readFile } from 'node:fs/promises';
const module = new WebAssembly.Module(await readFile('./rewritten.wasm'), {
  builtins: ['js-string'], importedStringConstants: 'wasm:js/string-constants',
});
const imports = WebAssembly.Module.imports(module);
if (!imports.every(entry => entry.module === './module.imports.mjs')) throw Error('Unexpected host dependency');
console.log(imports.length);
''');
      final validation = await Process.run('node', [
        'validate.mjs',
      ], workingDirectory: directory.path);
      expect(
        validation.exitCode,
        0,
        reason: '${validation.stdout}${validation.stderr}',
      );
      expect(
        int.parse((validation.stdout as String).trim()),
        rewritten.imports.length,
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

List<int> _unsigned(int value) {
  final bytes = <int>[];
  do {
    final byte = value & 0x7f;
    value >>= 7;
    bytes.add(value == 0 ? byte : byte | 0x80);
  } while (value != 0);
  return bytes;
}

List<int> _name(String value) {
  final bytes = utf8.encode(value);
  return [..._unsigned(bytes.length), ...bytes];
}

List<int> _imports(List<(String, String, List<int>)> entries) => [
  ..._unsigned(entries.length),
  for (final (module, name, descriptor) in entries) ...[
    ..._name(module),
    ..._name(name),
    ...descriptor,
  ],
];

List<int> _section(int id, List<int> payload) => [
  id,
  ..._unsigned(payload.length),
  ...payload,
];
Uint8List _module(List<int> imports) =>
    Uint8List.fromList([..._header, ..._section(2, imports)]);

List<List<int>> _otherSections(Uint8List bytes) {
  final sections = <List<int>>[];
  var offset = 8;
  while (offset < bytes.length) {
    final start = offset;
    final id = bytes[offset++];
    var length = 0;
    var shift = 0;
    int next;
    do {
      next = bytes[offset++];
      length |= (next & 0x7f) << shift;
      shift += 7;
    } while (next >= 0x80);
    offset += length;
    if (id != 2) sections.add(bytes.sublist(start, offset));
  }
  return sections;
}
