import 'dart:convert';

import 'wasm.dart';

/// Adapts the compiler's generated host helpers to native Wasm ESM imports.
String generateHost(
  String compilerSource,
  List<WasmImport> imports, {
  String wasmFile = 'module.wasm',
}) {
  const startMarker = '    let dartInstance;\n';
  const tableMarker = '    const dart2wasm = {\n';
  const baseMarker = '    const baseImports = {\n';
  const endMarker = '    const jsStringPolyfill = {\n';
  final start = _marker(compilerSource, startMarker) + startMarker.length;
  final table = _marker(compilerSource, tableMarker);
  final base = _marker(compilerSource, baseMarker);
  final end = _marker(compilerSource, endMarker);
  if (!(start < table && table < base && base < end)) {
    throw const FormatException('Unsupported Dart compiler host layout.');
  }
  final helperTable = compilerSource.substring(table, base);
  final stackHelper = helperTable.indexOf(_sdkExceptionStackHelper);
  if (stackHelper < 0 ||
      helperTable.indexOf(_sdkExceptionStackHelper, stackHelper + 1) >= 0) {
    throw const FormatException(
      'Unsupported Dart compiler exception stack helper; expected one Dart 3.13.5 helper body.',
    );
  }
  final stackStart = table + stackHelper;
  final helpers =
      compilerSource.substring(start, stackStart) +
      _safeExceptionStackHelper +
      compilerSource.substring(
        stackStart + _sdkExceptionStackHelper.length,
        end,
      );
  final output = StringBuffer()
    ..writeln(_licenses)
    ..writeln('import * as dartExports from ${jsonEncode('./$wasmFile')};')
    ..writeln('const dartInstance = { exports: dartExports };')
    ..writeln(helpers)
    ..writeln(_napi);
  final bridgeImports = {
    for (final import in imports)
      if (import.module == 'napi') import.name,
  };
  if (bridgeImports.contains('snapshotMap') ||
      bridgeImports.contains('snapshotRecord')) {
    output.writeln(_ordinaryObjectHelper);
  }
  for (final name in bridgeImports) {
    final helper = _collectionHelpers[name];
    if (helper != null) output.writeln(helper);
  }
  for (final import in imports) {
    if (!RegExp(r'^_i[0-9]+$').hasMatch(import.alias)) {
      throw FormatException('Invalid Wasm import alias "${import.alias}".');
    }
    if ((import.module.isEmpty ||
            import.module == 'wasm:js/string-constants') &&
        import.kind == WasmImportKind.global) {
      output.writeln(
        'export const ${import.alias} = ${jsonEncode(import.name)};',
      );
      continue;
    }
    if (!_modules.contains(import.module) && import.module != 'napi') {
      throw FormatException(
        'Unsupported Dart Wasm host module "${import.module}".',
      );
    }
    if (import.module == 'napi' &&
        (!_napiFunctions.contains(import.name) ||
            import.kind != WasmImportKind.function)) {
      throw FormatException('Unsupported bridge import "${import.name}".');
    }
    if (import.module == 'dart2wasm' &&
        !RegExp(
          '^\\s+${RegExp.escape(import.name)}:',
          multiLine: true,
        ).hasMatch(compilerSource.substring(table, base))) {
      throw FormatException(
        'Dart compiler host helper "${import.name}" is missing.',
      );
    }
    final object = import.module == 'napi'
        ? 'napi'
        : 'baseImports[${jsonEncode(import.module)}]';
    output.writeln(
      'export const ${import.alias} = $object[${jsonEncode(import.name)}];',
    );
    output.writeln(
      'if (${import.kind == WasmImportKind.function ? 'typeof ${import.alias} !== "function"' : '${import.alias} === undefined'}) throw new Error(${jsonEncode('Unavailable Wasm host import ${import.module}.${import.name}')});',
    );
  }
  return output.toString();
}

int _marker(String source, String marker) {
  final index = source.indexOf(marker);
  if (index < 0 || source.indexOf(marker, index + marker.length) >= 0) {
    throw const FormatException(
      'Unsupported Dart compiler host layout; expected Dart 3.13.5 generated JavaScript.',
    );
  }
  return index;
}

// Match the generated function body, not its compiler-minified field name.
const _sdkExceptionStackHelper = '''(exn) => {
        if (exn instanceof Error) {
          return exn.stack;
        } else {
          return null;
        }
      }''';

// Extracting diagnostic metadata must never replace the exception itself.
const _safeExceptionStackHelper = '''(exn) => {
        try {
          if (exn instanceof Error) {
            const stack = exn.stack;
            return typeof stack === 'string' ? stack : null;
          }
        } catch (_) {}
        return null;
      }''';

const _modules = {
  'dart2wasm',
  'Math',
  'Date',
  'Object',
  'Array',
  'Reflect',
  'WebAssembly',
};

final _napiFunctions = {
  'kind',
  'copyBytes',
  'error',
  'rethrowError',
  ..._collectionHelpers.keys,
};

const _napi = r'''
const typedArrayPrototype = Object.getPrototypeOf(Uint8Array.prototype);
const typedTag = Object.getOwnPropertyDescriptor(typedArrayPrototype, Symbol.toStringTag).get;
const napi = {
  kind(value) {
    if (typeof value === 'number') return 1;
    if (typeof value === 'boolean') return 2;
    if (typeof value === 'string') return 3;
    if (value !== null && typeof value === 'object' &&
        Reflect.apply(typedTag, value, []) === 'Uint8Array') return 4;
    return 0;
  },
  copyBytes(value) { return new Uint8Array(value); },
  error(kind, message, stack) {
    const error = kind === 1 ? new TypeError(message)
      : kind === 2 ? new RangeError(message) : new Error(message);
    if (stack !== null) error.dartStack = stack;
    return error;
  },
  rethrowError(error) { throw error; },
};
''';

const _ordinaryObjectHelper = r'''
function napiRequireObject(value, context) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new TypeError(context + ': Expected an ordinary object');
  }
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== null && prototype !== Object.prototype) {
    const constructor = Object.getOwnPropertyDescriptor(prototype, 'constructor');
    const ctor = constructor && constructor.value;
    if (Object.getPrototypeOf(prototype) !== null || typeof ctor !== 'function' ||
        Object.getOwnPropertyDescriptor(ctor, 'prototype')?.value !== prototype ||
        Function.prototype.toString.call(ctor) !== Function.prototype.toString.call(Object)) {
      throw new TypeError(context + ': Expected an ordinary or null-prototype object');
    }
  }
}
''';

// Only helpers referenced by the compiled Wasm imports are emitted.
const _collectionHelpers = {
  'arrayLength': 'napi.arrayLength = value => value.length;',
  'arrayGet': 'napi.arrayGet = (value, index) => value[index >>> 0];',
  'arraySet': r'''
napi.arraySet = (value, index, element) => {
  Object.defineProperty(value, index >>> 0, {
    value: element, writable: true, enumerable: true, configurable: true,
  });
};
''',
  'newList': 'napi.newList = length => new Array(length >>> 0);',
  'snapshotList': r'''
napi.snapshotList = (value, context) => {
  if (!Array.isArray(value)) throw new TypeError(context + ': Expected an Array');
  const length = Object.getOwnPropertyDescriptor(value, 'length').value;
  if (typeof length !== 'number') {
    throw new TypeError(context + ': Expected a numeric Array length');
  }
  if (!Number.isInteger(length) || length < 0 || length > 0xffffffff) {
    throw new RangeError(context + ': Expected a valid Array length');
  }
  const snapshot = new Array(length);
  for (let index = 0; index < length; index++) {
    const descriptor = Object.getOwnPropertyDescriptor(value, index);
    if (!descriptor || !Object.hasOwn(descriptor, 'value')) {
      throw new TypeError(context + '[' + index + ']: Expected an own data index');
    }
    Object.defineProperty(snapshot, index, {
      value: descriptor.value, writable: true, enumerable: true, configurable: true,
    });
  }
  return snapshot;
};
''',
  'newMap': 'napi.newMap = () => Object.create(null);',
  'mapSet': r'''
napi.mapSet = (value, key, element) => {
  Object.defineProperty(value, key, {
    value: element, writable: true, enumerable: true, configurable: true,
  });
};
''',
  'snapshotMap': r'''
napi.snapshotMap = (value, context) => {
  napiRequireObject(value, context);
  const snapshot = [];
  let index = 0;
  for (const key of Reflect.ownKeys(value)) {
    if (typeof key !== 'string') continue;
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor || !descriptor.enumerable) continue;
    if (!Object.hasOwn(descriptor, 'value')) {
      throw new TypeError(context + '[' + JSON.stringify(key) + ']: Expected an own data property');
    }
    Object.defineProperty(snapshot, index++, {
      value: key, writable: true, enumerable: true, configurable: true,
    });
    Object.defineProperty(snapshot, index++, {
      value: descriptor.value, writable: true, enumerable: true, configurable: true,
    });
  }
  return snapshot;
};
''',
  'snapshotRecord': r'''
napi.snapshotRecord = (value, names, context) => {
  napiRequireObject(value, context);
  const snapshot = new Array(names.length);
  for (let index = 0; index < names.length; index++) {
    const key = names[index];
    const descriptor = Object.getOwnPropertyDescriptor(value, key);
    if (!descriptor || !Object.hasOwn(descriptor, 'value')) {
      throw new TypeError(context + '[' + JSON.stringify(key) + ']: Expected an own data property');
    }
    Object.defineProperty(snapshot, index, {
      value: descriptor.value, writable: true, enumerable: true, configurable: true,
    });
  }
  return snapshot;
};
''',
};

const _licenses = r'''
/*
MIT License

Copyright (c) 2026 Seven Du

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

The Dart compiler-generated host helpers below are distributed under the
BSD 3-Clause License:

Copyright 2012, the Dart project authors.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
* Redistributions of source code must retain the above copyright notice,
  this list of conditions and the following disclaimer.
* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.
* Neither the name of Google LLC nor the names of its contributors may be
  used to endorse or promote products derived from this software without
  specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.
*/
''';
