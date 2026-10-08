import 'dart:convert';

import 'exports.dart';

/// A dependency-free implementation of the synchronous Node-API subset used
/// by the generated bridge. Each instance and callback owns its handles and arena.
String generateRuntime(
  List<Export> exports, {
  String dartLoader = 'module.mjs',
}) => _runtime
    .replaceAll('__DART_LOADER__', jsonEncode('./$dartLoader'))
    .replaceAll(
      '__CALLBACKS__',
      jsonEncode(
        List.generate(exports.length, (index) => 'napi_dart_callback_$index'),
      ),
    );

const _runtime = r'''
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
*/
import { compile } from __DART_LOADER__;

// Standard wasm32 Node-API signatures. Only the generated bridge's synchronous
// subset is provided; this is not a general native-addon runtime.
export async function instantiate(bytes) {
  const compiled = await compile(bytes);
  const memory = new WebAssembly.Memory({ initial: 1, maximum: 32768 });
  const callbacks = __CALLBACKS__;
  const table = new WebAssembly.Table({ element: 'anyfunc', initial: callbacks.length + 1 });
  const handles = new Map();
  const scopes = [];
  const buffers = new WeakMap();
  const decoder = new TextDecoder();
  let nextHandle = 1;
  let cursor = 8;
  let view = new DataView(memory.buffer);

  function current() {
    if (!scopes.length) throw new Error('Node-API call outside a callback scope');
    return scopes[scopes.length - 1];
  }
  function openScope() {
    const scope = { mark: cursor, handles: [], pending: null };
    scopes.push(scope);
    return scope;
  }
  function closeScope(scope) {
    for (const handle of scope.handles) handles.delete(handle);
    cursor = scope.mark;
    scopes.pop();
  }
  function keep(value) {
    while (handles.has(nextHandle)) nextHandle = nextHandle === 0x7fffffff ? 1 : nextHandle + 1;
    const handle = nextHandle;
    nextHandle = nextHandle === 0x7fffffff ? 1 : nextHandle + 1;
    handles.set(handle, value);
    current().handles.push(handle);
    return handle;
  }
  function get(handle) {
    if (!handles.has(handle)) throw new Error('Invalid Node-API value handle');
    return handles.get(handle);
  }
  function range(pointer, length) {
    pointer >>>= 0;
    if (!Number.isSafeInteger(length) || length < 0 || pointer + length > memory.buffer.byteLength)
      throw new RangeError('Node-API memory access is out of bounds');
    return pointer;
  }
  function heap() {
    if (view.buffer !== memory.buffer) view = new DataView(memory.buffer);
    return view;
  }
  function u32(pointer) { return heap().getUint32(range(pointer, 4), true); }
  function put32(pointer, value) { heap().setUint32(range(pointer, 4), value, true); }
  function put64(pointer, value) { heap().setFloat64(range(pointer, 8), value, true); }
  function allocate(length) {
    current();
    if (!Number.isSafeInteger(length) || length < 0 || length > 0x7ffffff0)
      throw new RangeError('Node-API allocation is too large');
    const start = cursor;
    const end = Math.ceil((start + Math.max(length, 1)) / 8) * 8;
    if (end > 0x80000000) throw new RangeError('Node-API arena exceeds 2 GiB');
    if (end > memory.buffer.byteLength)
      memory.grow(Math.ceil((end - memory.buffer.byteLength) / 65536));
    cursor = end;
    return start;
  }
  function utf8(pointer, length = -1) {
    pointer = range(pointer, 0);
    const bytes = new Uint8Array(memory.buffer);
    if (length === -1 || length === 0xffffffff) {
      let end = pointer;
      while (end < bytes.length && bytes[end]) end++;
      if (end === bytes.length) throw new RangeError('Unterminated UTF-8 string');
      length = end - pointer;
    }
    return decoder.decode(bytes.subarray(pointer, range(pointer, length) + length));
  }
  function checked(fn) {
    return (env, ...args) => {
      if (env !== 1 || !scopes.length) return 1;
      try { return fn(...args); }
      catch (error) { current().pending = error; return 10; }
    };
  }
  const typedArrayPrototype = Object.getPrototypeOf(Uint8Array.prototype);
  const typedTag = Object.getOwnPropertyDescriptor(typedArrayPrototype, Symbol.toStringTag).get;
  const typedLength = Object.getOwnPropertyDescriptor(typedArrayPrototype, 'length').get;
  const typedBuffer = Object.getOwnPropertyDescriptor(typedArrayPrototype, 'buffer').get;
  const typedOffset = Object.getOwnPropertyDescriptor(typedArrayPrototype, 'byteOffset').get;
  const tag = value => Reflect.apply(typedTag, value, []);
  const napi = {
    memory,
    napi_dart_allocate: length => {
      try { return allocate(length >>> 0); }
      catch (error) { current().pending = error; return 0; }
    },
    napi_create_function: checked((name, length, callback, data, result) => {
      const rawCallback = table.get(callback);
      if (typeof rawCallback !== 'function') return 1;
      const fn = function (...args) {
        const scope = openScope();
        try {
          const info = keep({ args, receiver: this, data, newTarget: new.target });
          const value = rawCallback(1, info);
          if (scope.pending !== null) throw scope.pending;
          return value === 0 ? undefined : get(value);
        } finally { closeScope(scope); }
      };
      Object.defineProperty(fn, 'name', { value: name ? utf8(name, length) : '', configurable: true });
      put32(result, keep(fn));
      return 0;
    }),
    napi_set_named_property: checked((object, name, value) => {
      Object.defineProperty(get(object), utf8(name), { value: get(value), enumerable: true });
      return 0;
    }),
    napi_get_cb_info: checked((info, argc, argv, receiver, data) => {
      const call = get(info);
      if (argv) {
        if (!argc) return 1;
        const capacity = u32(argc);
        const count = Math.min(capacity, call.args.length);
        range(argv, capacity * 4);
        for (let index = 0; index < count; index++) put32(argv + index * 4, keep(call.args[index]));
        for (let index = count; index < capacity; index++) put32(argv + index * 4, keep(undefined));
      }
      if (argc) put32(argc, call.args.length);
      if (receiver) put32(receiver, keep(call.receiver));
      if (data) put32(data, call.data);
      return 0;
    }),
    napi_typeof: checked((value, result) => {
      const object = get(value);
      const type = object === null ? 1 : { undefined: 0, boolean: 2, number: 3,
        string: 4, symbol: 5, object: 6, function: 7, bigint: 9 }[typeof object];
      put32(result, type);
      return 0;
    }),
    napi_get_value_bool: checked((value, result) => {
      const object = get(value);
      if (typeof object !== 'boolean') return 7;
      heap().setUint8(range(result, 1), object ? 1 : 0);
      return 0;
    }),
    napi_get_value_double: checked((value, result) => {
      const object = get(value);
      if (typeof object !== 'number') return 6;
      put64(result, object);
      return 0;
    }),
    napi_get_boolean: checked((value, result) => { put32(result, keep(value !== 0)); return 0; }),
    napi_create_double: checked((value, result) => { put32(result, keep(value)); return 0; }),
    napi_get_null: checked(result => { put32(result, keep(null)); return 0; }),
    napi_get_undefined: checked(result => { put32(result, keep(undefined)); return 0; }),
    napi_get_value_string_utf16: checked((value, buffer, capacity, result) => {
      const text = get(value);
      if (typeof text !== 'string') return 3;
      if (!buffer) { if (result) put32(result, text.length); return 0; }
      capacity >>>= 0;
      range(buffer, capacity * 2);
      const count = Math.min(text.length, Math.max(0, capacity - 1));
      for (let index = 0; index < count; index++) heap().setUint16(buffer + index * 2, text.charCodeAt(index), true);
      if (capacity) heap().setUint16(buffer + count * 2, 0, true);
      if (result) put32(result, count);
      return 0;
    }),
    napi_create_string_utf16: checked((pointer, length, result) => {
      length >>>= 0;
      if (length === 0xffffffff) {
        length = 0;
        while (heap().getUint16(range(pointer + length * 2, 2), true)) length++;
      }
      range(pointer, length * 2);
      let text = '';
      for (let start = 0; start < length; start += 4096) {
        const chunk = [];
        for (let index = start; index < Math.min(start + 4096, length); index++)
          chunk.push(heap().getUint16(pointer + index * 2, true));
        text += String.fromCharCode(...chunk);
      }
      put32(result, keep(text));
      return 0;
    }),
    napi_is_typedarray: checked((value, result) => {
      heap().setUint8(range(result, 1), tag(get(value)) !== undefined ? 1 : 0);
      return 0;
    }),
    napi_get_typedarray_info: checked((value, type, length, data, arraybuffer, byteOffset) => {
      const object = get(value);
      if (tag(object) !== 'Uint8Array') return 1;
      const size = Reflect.apply(typedLength, object, []);
      const offset = Reflect.apply(typedOffset, object, []);
      const buffer = Reflect.apply(typedBuffer, object, []);
      const pointer = allocate(size);
      new Uint8Array(memory.buffer, pointer, size).set(new Uint8Array(buffer, offset, size));
      if (type) put32(type, 1);
      if (length) put32(length, size);
      if (data) put32(data, pointer);
      if (arraybuffer) put32(arraybuffer, keep(buffer));
      if (byteOffset) put32(byteOffset, offset);
      return 0;
    }),
    napi_create_arraybuffer: checked((length, data, result) => {
      length >>>= 0;
      const buffer = new ArrayBuffer(length);
      const pointer = allocate(length);
      buffers.set(buffer, { pointer, length });
      if (data) put32(data, pointer);
      put32(result, keep(buffer));
      return 0;
    }),
    napi_create_typedarray: checked((type, length, arraybuffer, offset, result) => {
      if (type !== 1) return 1;
      const buffer = get(arraybuffer);
      const allocation = buffers.get(buffer);
      if (!allocation) return 1;
      range(allocation.pointer, allocation.length);
      new Uint8Array(buffer).set(new Uint8Array(memory.buffer, allocation.pointer, allocation.length));
      put32(result, keep(new Uint8Array(buffer, offset >>> 0, length >>> 0)));
      return 0;
    }),
    napi_throw_type_error: checked((code, message) => { current().pending = new TypeError(utf8(message)); return 0; }),
    napi_throw_range_error: checked((code, message) => { current().pending = new RangeError(utf8(message)); return 0; }),
    napi_throw_error: checked((code, message) => { current().pending = new Error(utf8(message)); return 0; }),
  };
  const app = await compiled.instantiate({ env: napi });
  for (let index = 0; index < callbacks.length; index++) table.set(index + 1, app.instantiatedModule.exports[callbacks[index]]);
  const scope = openScope();
  try {
    const binding = Object.create(null);
    const result = app.instantiatedModule.exports.napi_register_wasm_v1(1, keep(binding));
    if (scope.pending !== null) throw scope.pending;
    return { exports: result === 0 ? binding : get(result) };
  } finally { closeScope(scope); }
}
''';
