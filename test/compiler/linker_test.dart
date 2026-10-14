import 'dart:convert';
import 'dart:io';

import 'package:napi/src/compiler/linker/dart_module_linker.dart';
import 'package:test/test.dart';

void main() {
  test('rewrites imports and preserves every non-import section exactly', () {
    final original = _module([
      _import('dart2wasm', 'a', [0, 0]),
      _import('', 'a string 🦊', [3, 0x64, 0x6f, 0]),
      _import('WebAssembly', 'JSTag', [4, 0, 0]),
      _import('Math', 'sqrt', [0, 0]),
      _import('wasm:js-string', 'concat', [0, 0]),
      _import('napi', 'validate', [0, 0]),
    ]);
    final linked = linkDartModule(
      rawWasmBytes: original,
      rawMjsText: _hostFixture,
      hostSpecifier: './host.mjs',
      coreSpecifier: './module.wasm',
      additionalImports: {'napi': './boundary.mjs'},
    );
    final before = _sections(original);
    final after = _sections(linked.wasmBytes);
    expect(
      after.where((section) => section.first != 2),
      before.where((section) => section.first != 2),
    );
    final importSection = after.singleWhere((section) => section.first == 2);
    final text = utf8.decode(importSection, allowMalformed: true);
    expect(text, contains('./host.mjs'));
    expect(text, contains('./boundary.mjs'));
    expect(text, contains('wasm:js-string'));
    expect(text, isNot(contains('dart2wasm')));
    expect(linked.hostJavaScript, contains('"a string 🦊"'));
    expect(linked.hostJavaScript, contains('dart2wasm["a"]'));
    expect(linked.hostJavaScript, contains('WebAssembly.JSTag'));
  });

  test('unknown imports and mismatched known import kinds fail closed', () {
    for (final import in [
      _import('unknown', 'anything', [0, 0]),
      _import('wasm:js-string', 'unknownBuiltin', [0, 0]),
      _import('WebAssembly', 'Memory', [4, 0, 0]),
      _import('', 'mutable', [3, 0x6f, 1]),
      _import('', 'numeric', [3, 0x7f, 0]),
      _import('dart2wasm', 'table', [1]),
    ]) {
      expect(() => _link(_module([import])), throwsA(isA<WasmLinkException>()));
    }
  });

  test('truncated or malformed binaries fail before publishing output', () {
    final valid = _module([
      _import('dart2wasm', 'a', [0, 0]),
    ]);
    for (final bytes in [
      <int>[],
      [0, 0x61, 0x73, 0x6d, 2, 0, 0, 0],
      [..._header, 2, 0x80],
      [..._header, 2, 0xff, 0xff, 0xff, 0xff, 0x10],
      valid.sublist(0, valid.length - 1),
      [..._header, 2, 1, 0, 2, 1, 0],
    ]) {
      expect(() => _link(bytes), throwsA(isA<WasmLinkException>()));
    }
  });

  test('compiler namespaces and unsafe generated specifiers are rejected', () {
    expect(
      () => linkDartModule(
        rawWasmBytes: _module([]),
        rawMjsText: _hostFixture,
        hostSpecifier: './host.mjs',
        coreSpecifier: './module.wasm',
        additionalImports: {'dart2wasm': './custom.mjs'},
      ),
      throwsArgumentError,
    );
    for (final specifier in ['node:fs', '/host.mjs', './host.mjs#x']) {
      expect(
        () => buildPublicWasmFacade(
          hostSpecifier: specifier,
          exportNames: ['Counter'],
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => buildPublicWasmFacade(
        hostSpecifier: './host.mjs',
        exportNames: ['Counter', 'Counter'],
      ),
      throwsArgumentError,
    );
  });

  test('public facade rejects Promise-sensitive and reserved ESM names', () {
    for (final name in ['then', 'wasm:entry', 'wasm-js:entry']) {
      expect(
        () => buildPublicWasmFacade(
          hostSpecifier: './host.mjs',
          exportNames: [name],
        ),
        throwsA(
          isA<WasmLinkException>().having(
            (error) => error.code,
            'diagnostic',
            'NAPI_WASM_EXPORT_NAME',
          ),
        ),
      );
    }
  });

  test(
    'native Wasm facade preserves JS function and constructor values',
    () async {
      final directory = await Directory.systemTemp.createTemp('napi-facade-');
      addTearDown(() => directory.delete(recursive: true));
      await File('${directory.path}/module.wasm').writeAsBytes(
        buildPublicWasmFacade(
          hostSpecifier: './host.mjs',
          exportNames: ['Counter', 'arity'],
        ),
      );
      await File('${directory.path}/host.mjs').writeAsString('''
export class Counter { constructor(value) { this.value = value; } }
export function arity() { return arguments.length; }
''');
      await File('${directory.path}/consumer.mjs').writeAsString('''
import assert from 'node:assert/strict';
import {Counter, arity} from './module.wasm';
import {Counter as HostCounter, arity as hostArity} from './host.mjs';
assert.equal(Counter, HostCounter);
assert.equal(arity, hostArity);
assert.equal(new Counter(9).value, 9);
assert.throws(() => Counter(9), TypeError);
assert.equal(arity(), 0);
assert.equal(arity(undefined), 1);
assert.equal(arity(null), 1);
console.log('native-facade-ok');
''');
      final result = await Process.run('node', [
        '${directory.path}/consumer.mjs',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('native-facade-ok'));
    },
  );
}

LinkedDartModule _link(List<int> bytes) => linkDartModule(
  rawWasmBytes: bytes,
  rawMjsText: _hostFixture,
  hostSpecifier: './host.mjs',
  coreSpecifier: './module.wasm',
);

const _header = [0, 0x61, 0x73, 0x6d, 1, 0, 0, 0];
List<int> _u32(int value) {
  final result = <int>[];
  do {
    final byte = value & 127;
    value >>= 7;
    result.add(byte | (value == 0 ? 0 : 128));
  } while (value != 0);
  return result;
}

List<int> _name(String name) => [
  ..._u32(utf8.encode(name).length),
  ...utf8.encode(name),
];
List<int> _import(String module, String name, List<int> descriptor) => [
  ..._name(module),
  ..._name(name),
  ...descriptor,
];
List<int> _section(int id, List<int> payload) => [
  id,
  ..._u32(payload.length),
  ...payload,
];
List<int> _module(List<List<int>> imports) => [
  ..._header,
  ..._section(0, [..._name('before'), 0, 1, 2]),
  ..._section(2, [
    ..._u32(imports.length),
    ...imports.expand((value) => value),
  ]),
  ..._section(8, [0]),
  ..._section(0, [
    ..._name('sourceMappingURL'),
    ...utf8.encode('raw.wasm.map'),
  ]),
];

List<List<int>> _sections(List<int> bytes) {
  var offset = 8;
  final result = <List<int>>[];
  while (offset < bytes.length) {
    final start = offset++;
    var size = 0;
    var shift = 0;
    while (true) {
      final byte = bytes[offset++];
      size |= (byte & 127) << shift;
      shift += 7;
      if (byte < 128) break;
    }
    offset += size;
    result.add(bytes.sublist(start, offset));
  }
  return result;
}

// A deliberately small synthetic loader of the recognized pinned shape.
const _hostFixture = '''
const builtins = {builtins: ['js-string']};
const builtins = {builtins: ['js-string']};
  async instantiate(additionalImports, {loadDeferredModules, loadDeferredId} = {}) {
    let dartInstance;

    // Prints to the console
    function printToConsole(value) { console.log(value); }
    const dart2wasm = {
      a: () => 1,
    };

    const baseImports = {
      dart2wasm: dart2wasm,
      Math: Math,
      Date: Date,
      Object: Object,
      Array: Array,
      Reflect: Reflect,
      WebAssembly: {
        JSTag: WebAssembly.JSTag,
      },
      "": new Proxy({}, { get(_, prop) { return prop; } }),

    };

    const jsStringPolyfill = {
    };

    dartInstance = await WebAssembly.instantiate(this.module, {
      ...baseImports,
      ...additionalImports,
      
      "wasm:js-string": jsStringPolyfill,
    });

    return new InstantiatedApp(this, dartInstance);
''';
