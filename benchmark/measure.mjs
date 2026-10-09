import assert from 'node:assert/strict';
import { arch, cpus, platform, release } from 'node:os';
import { performance } from 'node:perf_hooks';

const args = {};
for (let i = 2; i + 1 < process.argv.length; i += 2) args[process.argv[i]] = process.argv[i + 1];
if (process.argv[2] === '--cold') {
  const start = performance.now();
  const module = await import(process.argv[3]);
  const imported = performance.now();
  const name = process.argv[4];
  const result = name === 'add' ? module.add(1.5, 2.5) : module.answer();
  const completed = result instanceof Promise ? await result : result;
  const firstCall = performance.now() - imported;
  assert.equal(completed, name === 'add' ? 4 : 42);
  console.log(JSON.stringify({ import_ms: imported - start, first_call_ms: firstCall }));
} else {
  await measure();
}

async function measure() {
  const group = args['--group'] ?? 'all';
  if (!['all', 'records', 'batch'].includes(group)) throw new Error(`Unknown group ${group}; use all, records, or batch.`);
  const all = group === 'all';
  const iterations = Number(args['--iterations']);
  const warmup = Number(args['--warmup']);
  const runs = Number(args['--runs']);
  const wasm = {
    ...(all ? await import(args['--wasm']) : {}),
    ...(all ? await import(args['--collections']) : {}),
    ...await import(args['--records']),
    ...(group !== 'records' ? await import(args['--batch']) : {}),
  };
  if (all) {
    globalThis.self = globalThis; // dart compile js emits a browser-compatible global.
    await import(args['--dart-js']);
  }
  const dart = globalThis.dartBaseline;
  const tag = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), Symbol.toStringTag).get;
  const number = value => {
    if (typeof value !== 'number') throw new TypeError('Expected a number');
    return value;
  };
  const integer = value => {
    number(value);
    if (!Number.isSafeInteger(value)) throw new RangeError('Expected a safe integer');
    return value;
  };
  const string = value => {
    if (typeof value !== 'string') throw new TypeError('Expected a string');
    return value;
  };
  const bytes = value => {
    if (value === null || typeof value !== 'object' || Reflect.apply(tag, value, []) !== 'Uint8Array') throw new TypeError('Expected Uint8Array');
    return value;
  };
  const listSnapshot = value => {
    if (!Array.isArray(value)) throw new TypeError('Expected Array');
    const output = [];
    for (let i = 0; i < value.length; i++) {
      const field = Object.getOwnPropertyDescriptor(value, String(i));
      if (!field || !Object.hasOwn(field, 'value')) throw new TypeError('Expected dense data indices');
      output.push(integer(field.value));
    }
    return output;
  };
  const mapSnapshot = value => {
    if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new TypeError('Expected ordinary object');
    const proto = Object.getPrototypeOf(value);
    if (proto !== null && proto !== Object.prototype) throw new TypeError('Expected ordinary object');
    const output = Object.create(null);
    for (const key of Object.keys(value)) {
      const field = Object.getOwnPropertyDescriptor(value, key);
      if (!Object.hasOwn(field, 'value')) throw new TypeError('Expected data properties');
      output[key] = string(field.value);
    }
    return output;
  };
  const js = all ? {
    add: (a, b) => number(a) + number(b),
    identityInt: value => integer(value),
    echoString: value => string(value),
    stringLength: value => string(value).length,
    echoBytes: value => new Uint8Array(new Uint8Array(bytes(value))),
    sumBytes(value) {
      let sum = 0;
      for (const byte of new Uint8Array(bytes(value))) sum += byte;
      return sum;
    },
    fail() { throw new Error('Bad state: benchmark failure'); },
    async addAsync(a, b) { return js.add(a, b); },
    async echoStringAsync(value) { return js.echoString(value); },
    async echoBytesAsync(value) { return js.echoBytes(value); },
    async failAsync() { return js.fail(); },
    echoList(value) { return listSnapshot(value).map(integer); },
    sumList(value) { return listSnapshot(value).reduce((sum, item) => sum + item, 0); },
    echoMap(value) {
      const snapshot = mapSnapshot(value);
      const result = Object.create(null);
      for (const key of Object.keys(snapshot)) result[key] = string(snapshot[key]);
      return result;
    },
    async echoListAsync(value) { return js.echoList(value); },
    async echoMapAsync(value) { return js.echoMap(value); },
  } : {};
  // These checks match the valid-input boundary. Copies execute inside the
  // compiled Dart interop entry, so no copy is skipped or counted a third time.
  const dartJs = all ? {
    add: (a, b) => dart.add(number(a), number(b)),
    identityInt: value => integer(dart.identityInt(integer(value))),
    echoString: value => dart.echoString(string(value)),
    stringLength: value => dart.stringLength(string(value)),
    echoBytes: value => dart.echoBytes(bytes(value)),
    sumBytes: value => dart.sumBytes(bytes(value)),
    addAsync: (a, b) => dart.addAsync(number(a), number(b)),
    echoStringAsync: value => dart.echoStringAsync(string(value)),
    echoBytesAsync: value => dart.echoBytesAsync(bytes(value)),
  } : null;
  const implementations = [['wasm', wasm], ['javascript', js], ...(all ? [['dart_javascript', dartJs]] : [])];
  if (all) {
    for (const [, api] of implementations) {
      assert.equal(api.add(1.5, 2.5), 4);
      assert.equal(api.identityInt(Number.MAX_SAFE_INTEGER), Number.MAX_SAFE_INTEGER);
      assert.equal(api.echoString('Aé😀\ud800'), 'Aé😀\ud800');
      assert.equal(api.stringLength('Aé😀\ud800'), 5);
      const input = Uint8Array.of(7, 8);
      const output = api.echoBytes(input);
      assert.deepEqual(output, input);
      assert.notEqual(output.buffer, input.buffer);
      output[0] = 99;
      assert.equal(input[0], 7);
      const promise = api.echoBytesAsync(input);
      input[0] = 42;
      const asyncOutput = await promise;
      assert.equal(asyncOutput[0], 7);
      assert.notEqual(asyncOutput.buffer, input.buffer);
      assert.equal(await api.addAsync(1.5, 2.5), 4);
    }
  }
  const sized = (count, size) => Math.max(50, Math.floor(count * 64 / Math.max(64, size)));
  const cases = all ? [
    { name: 'numeric/add', count: iterations, warmup, input: '[i & 1023, 0.25]', call: (api, i) => api.add(i & 1023, 0.25) },
    { name: 'numeric/int-safe53', count: iterations, warmup, input: 'MAX_SAFE_INTEGER - (i & 1023)', call: (api, i) => api.identityInt(Number.MAX_SAFE_INTEGER - (i & 1023)) },
    { name: 'async/add', count: Math.max(50, Math.floor(iterations / 10)), warmup: Math.max(10, Math.floor(warmup / 10)), async: true, input: '[i & 1023, 0.25]', call: (api, i) => api.addAsync(i & 1023, 0.25) },
  ] : [];
  for (const [fields, method, input] of [
    [1, 'echoOne', { id: 42 }],
    [4, 'echoFour', { active: true, id: 42, name: 'Aé😀\ud800', score: 1.25 }],
    [16, 'echoSixteen', Object.fromEntries(Array.from({ length: 4 }, (_, i) => [
      [`active${i}`, true], [`id${i}`, 42 + i],
      [`name${i}`, `Aé😀\ud800:${i}`], [`score${i}`, 1.25 + i],
    ]).flat())],
  ]) {
    const keys = Object.keys(input).sort();
    // This reference covers the measured valid, current-realm data shapes.
    // It does not duplicate napi's complete Proxy/error/cross-realm contract.
    js[method] = value => {
      const proto = Object.getPrototypeOf(value);
      if (proto !== null && proto !== Object.prototype) throw new TypeError('Expected ordinary object');
      const snapshot = keys.map(key => {
        const field = Object.getOwnPropertyDescriptor(value, key);
        if (!field || !Object.hasOwn(field, 'value')) throw new TypeError('Expected own data property');
        return field.value;
      });
      const output = Object.create(null);
      for (let i = 0; i < keys.length; i++) {
        const key = keys[i];
        let value = snapshot[i];
        if (key.startsWith('id')) value = integer(value);
        else if (key.startsWith('score')) value = number(value);
        else if (key.startsWith('name')) value = string(value);
        else if (typeof value !== 'boolean') throw new TypeError('Expected a boolean');
        Object.defineProperty(output, key, { value, writable: true, enumerable: true, configurable: true });
      }
      return output;
    };
    if (group !== 'batch') js[`${method}Async`] = async value => js[method](value);
    if (group !== 'batch' || fields === 4) {
      for (const [, api] of implementations.slice(0, 2)) {
        const output = api[method](input);
        assert.deepEqual({ ...output }, input);
        assert.equal(Object.getPrototypeOf(output), null);
        assert.notEqual(output, input);
        output[keys[0]] = 'changed output';
        assert.deepEqual({ ...api[method](input) }, input);
        if (group !== 'batch') {
          const owned = { ...input };
          const pending = api[`${method}Async`](owned);
          owned[keys[0]] = 'changed input';
          assert.deepEqual({ ...await pending }, input);
        }
      }
    }
    if (group !== 'batch') {
      for (const asynchronous of [false, true]) {
        const count = asynchronous ? Math.max(50, Math.floor(iterations / 10)) : iterations;
        const warm = asynchronous ? Math.max(10, Math.floor(warmup / 10)) : warmup;
        cases.push({ name: `${asynchronous ? 'async/' : ''}record/echo/${fields}`, count, warmup: warm,
          async: asynchronous, implementations: ['wasm', 'javascript'],
          input: { fields, ownership_copies: 2, validation: 'fixed own data descriptors', scalars: fields === 1 ? 'int' : 'bool/int/String/double' },
          call: api => api[asynchronous ? `${method}Async` : method](input) });
      }
    }
  }
  if (group !== 'batch') {
    // Valid current-realm input reference: fixed own descriptors, a string
    // field and two real payload copies. Complete boundary/error semantics
    // and Dart's owned business input are covered by runtime acceptance.
    js.echoPacket = value => {
      const proto = Object.getPrototypeOf(value);
      if (proto !== null && proto !== Object.prototype) throw new TypeError('Expected ordinary object');
      const snapshot = ['name', 'payload'].map(key => {
        const field = Object.getOwnPropertyDescriptor(value, key);
        if (!field || !Object.hasOwn(field, 'value')) throw new TypeError('Expected own data property');
        return field.value;
      });
      const name = string(snapshot[0]);
      const payload = new Uint8Array(bytes(snapshot[1]));
      const output = Object.create(null);
      Object.defineProperty(output, 'name', { value: name, writable: true, enumerable: true, configurable: true });
      Object.defineProperty(output, 'payload', { value: new Uint8Array(payload), writable: true, enumerable: true, configurable: true });
      return output;
    };
    js.echoPacketPayload = value => new Uint8Array(new Uint8Array(bytes(value)));
    const name = 'Aé😀\ud800';
    for (const size of [32, 1024, 65536]) {
      const value = Uint8Array.from({ length: size }, (_, i) => i & 255);
      const buffer = Buffer.from(value);
      const owner = new Uint8Array(size + 16).fill(0xa5);
      owner.set(value, 8);
      const subarray = owner.subarray(8, 8 + size);
      for (const [kind, input] of [['Uint8Array', value], ['Buffer', buffer], ['subarray', subarray]]) {
        const expected = new Uint8Array(input);
        const packet = { name, payload: input };
        for (const [route, method, record] of [['echo', 'echoPacket', true], ['top-level', 'echoPacketPayload', false]]) {
          const label = `record/bytes/${route}/${kind}/${size}`;
          const invoke = api => api[method](record ? packet : input);
          // These echo checks prove observable view contents and independent
          // returned storage, not the hidden input copy before business entry.
          for (const [, api] of implementations.slice(0, 2)) {
            const output = invoke(api);
            if (record) {
              assert.equal(Object.getPrototypeOf(output), null, label);
              assert.deepEqual(Object.keys(output), ['name', 'payload'], label);
              assert.equal(output.name, name, label);
              for (const key of ['name', 'payload']) {
                const field = Object.getOwnPropertyDescriptor(output, key);
                assert(Object.hasOwn(field, 'value') && field.writable && field.enumerable && field.configurable, label);
              }
              assert.notEqual(output, packet, label);
            }
            const payload = record ? output.payload : output;
            assert.deepEqual(payload, expected, label);
            assert.equal(payload.byteLength, size, label);
            assert.equal(payload.byteOffset, 0, label);
            assert.notEqual(payload.buffer, input.buffer, label);
            payload[0] = 99;
            assert.deepEqual(new Uint8Array(input), expected, label);
            const second = invoke(api);
            const fresh = record ? second.payload : second;
            assert.deepEqual(fresh, expected, label);
            assert.notEqual(fresh.buffer, payload.buffer, label);
            input[0] = 42;
            assert.equal(fresh[0], 0, label);
            input[0] = 0;
            if (record) {
              output.name = 'changed output';
              assert.equal(packet.name, name, label);
              assert.equal(second.name, name, label);
            }
          }
          assert.equal(owner[7], 0xa5, label);
          assert.equal(owner[8 + size], 0xa5, label);
          cases.push({ name: label, count: sized(iterations, size), warmup: sized(warmup, size), implementations: ['wasm', 'javascript'],
            input: { bytes: size, kind, byte_offset: input.byteOffset, pattern: 'i & 255', ownership_copies: 2, method,
              fields: record ? 2 : 0, name_utf16_code_units: record ? name.length : 0,
              validation: record ? 'fixed own data descriptors, String and Uint8Array brand' : 'Uint8Array brand' },
            call: invoke });
        }
      }
    }
  }
  if (group !== 'records') {
    const recordListSnapshot = (value, convert) => {
      if (!Array.isArray(value)) throw new TypeError('Expected Array');
      const snapshot = [];
      for (let index = 0; index < value.length; index++) {
        const field = Object.getOwnPropertyDescriptor(value, index);
        if (!field || !Object.hasOwn(field, 'value')) throw new TypeError('Expected own data index');
        snapshot.push(field.value);
      }
      return snapshot.map(convert);
    };
    for (const method of ['echoOne', 'echoFour', 'echoSixteen']) {
      js[`${method}List`] = value => recordListSnapshot(value, js[method]);
    }
    js.echoFourListAsync = async value => js.echoFourList(value);
    js.normalizeOne = value => {
      const output = js.echoFour(value);
      output.name = output.name.trim();
      return output;
    };
    js.normalizeFourList = value => recordListSnapshot(value, js.normalizeOne);
    const readFour = value => {
      const proto = Object.getPrototypeOf(value);
      if (proto !== null && proto !== Object.prototype) throw new TypeError('Expected ordinary object');
      const values = ['active', 'id', 'name', 'score'].map(key => {
        const field = Object.getOwnPropertyDescriptor(value, key);
        if (!field || !Object.hasOwn(field, 'value')) throw new TypeError('Expected own data property');
        return field.value;
      });
      if (typeof values[0] !== 'boolean') throw new TypeError('Expected a boolean');
      return { active: values[0], id: integer(values[1]), name: string(values[2]), score: number(values[3]) };
    };
    js.sumOne = value => readFour(value).id;
    js.sumFourList = value => recordListSnapshot(value, readFour).reduce((sum, item) => sum + item.id, 0);
    const singleInput = { active: true, id: 42, name: ' Aé😀\ud800 ', score: 1.25 };
    for (const [, api] of implementations.slice(0, 2)) {
      const input = { ...singleInput };
      const output = api.normalizeOne(input);
      assert.deepEqual({ ...output }, { ...singleInput, name: singleInput.name.trim() });
      assert.equal(Object.getPrototypeOf(output), null);
      assert.notEqual(output, input);
      output.name = 'changed output';
      assert.equal(api.sumOne(input), singleInput.id);
      assert.deepEqual(input, singleInput);
    }
    for (const size of [0, 1, 16, 256, 4096]) {
      const input = Array.from({ length: size }, (_, i) => ({ active: !!(i & 1), id: i & 255, name: ` Aé😀\ud800:${i} `, score: i + .25 }));
      const normalized = input.map(item => ({ ...item, name: item.name.trim() }));
      const total = input.reduce((sum, item) => sum + item.id, 0);
      for (const [, api] of implementations.slice(0, 2)) {
        const output = api.echoFourList(input);
        assert.deepEqual(output.map(item => ({ ...item })), input);
        assert.notEqual(output, input);
        for (let i = 0; i < size; i++) {
          assert.notEqual(output[i], input[i]);
          assert.equal(Object.getPrototypeOf(output[i]), null);
        }
        assert.deepEqual(api.normalizeFourList(input).map(item => ({ ...item })), normalized);
        assert.equal(api.sumFourList(input), total);
        const owned = input.map(item => ({ ...item }));
        const pending = api.echoFourListAsync(owned);
        if (size) owned[0].name = 'changed field';
        owned.push({ active: true, id: 999, name: 'changed membership', score: 0 });
        assert.deepEqual((await pending).map(item => ({ ...item })), input);
      }
      for (const [kind, method, asynchronous, copies] of [
        ['echo', 'echoFourList', false, 2],
        ['async-echo', 'echoFourListAsync', true, 2],
        ['normalize', 'normalizeFourList', false, 2],
        ['sum', 'sumFourList', false, 1],
      ]) {
        cases.push({ name: `batch/${kind}/4/${size}`, count: sized(asynchronous ? iterations / 10 : iterations, size), warmup: sized(asynchronous ? warmup / 10 : warmup, size),
          async: asynchronous, implementations: ['wasm', 'javascript'],
          input: { elements: size, fields: 4, ownership_copies: copies, validation: 'own Array indices and fixed record data fields' }, call: api => api[method](input) });
      }
      for (const [kind, method, aggregate] of [['echo', 'echoFour', false], ['normalize', 'normalizeOne', false], ['sum', 'sumOne', true]]) {
        cases.push({ name: `batch/single-call-loop-${kind}/4/${size}`, count: sized(iterations, size), warmup: sized(warmup, size), implementations: ['wasm', 'javascript'],
          input: { elements: size, fields: 4, native_calls_per_iteration: size, outer_array_validation: false },
          call: api => aggregate ? input.reduce((sum, item) => sum + api[method](item), 0) : input.map(item => api[method](item)) });
      }
    }
    for (const [fields, method, input] of [
      [1, 'echoOneList', Array.from({ length: 16 }, (_, i) => ({ id: i }))],
      [16, 'echoSixteenList', Array.from({ length: 16 }, (_, row) => Object.fromEntries(Array.from({ length: 4 }, (_, i) => [
        [`active${i}`, true], [`id${i}`, row + i], [`name${i}`, `Aé😀\ud800:${row}:${i}`], [`score${i}`, row + i + .25],
      ]).flat()))],
    ]) {
      for (const [, api] of implementations.slice(0, 2)) assert.deepEqual(api[method](input).map(item => ({ ...item })), input);
      cases.push({ name: `batch/echo/${fields}/16`, count: sized(iterations, 16), warmup: sized(warmup, 16), implementations: ['wasm', 'javascript'],
        input: { elements: 16, fields, ownership_copies: 2 }, call: api => api[method](input) });
    }
  }
  if (all) {
    for (const size of [0, 1, 16, 256, 4096]) {
      const list = Array.from({ length: size }, (_, i) => i & 255);
      const map = Object.create(null);
      for (let i = 0; i < size; i++) map[`key${i}`] = `Aé😀\ud800:${i}`;
      for (const [, api] of implementations.slice(0, 2)) {
        const listOutput = api.echoList(list);
        assert.deepEqual(listOutput, list);
        assert.notEqual(listOutput, list);
        assert.equal(api.sumList(list), list.reduce((sum, item) => sum + item, 0));
        const mapOutput = api.echoMap(map);
        assert.deepEqual(mapOutput, map);
        assert.equal(Object.getPrototypeOf(mapOutput), null);
        assert.notEqual(mapOutput, map);
        const ownedList = [...list];
        const listPromise = api.echoListAsync(ownedList);
        ownedList.push(-1);
        assert.deepEqual(await listPromise, list);
        const ownedMap = Object.assign(Object.create(null), map);
        const mapPromise = api.echoMapAsync(ownedMap);
        ownedMap.extra = 'after-call';
        assert.deepEqual(await mapPromise, map);
      }
      for (const [kind, method, input, asynchronous, copies] of [
        ['list/echo/int', 'echoList', list, false, 2],
        ['list/sum/int', 'sumList', list, false, 1],
        ['map/echo/string', 'echoMap', map, false, 2],
        ['async/list-echo/int', 'echoListAsync', list, true, 2],
        ['async/map-echo/string', 'echoMapAsync', map, true, 2],
      ]) {
        cases.push({ name: `${kind}/${size}`, count: sized(asynchronous ? iterations / 10 : iterations, size), warmup: sized(asynchronous ? warmup / 10 : warmup, size), async: asynchronous, implementations: ['wasm', 'javascript'], input: { elements: size, ownership_copies: copies, leaf: kind.includes('string') ? 'UTF-16 String' : 'safe int', validation: 'own data descriptors' }, call: api => api[method](input) });
      }
    }
    for (const size of [16, 1024, 65536]) {
      const value = 'Aé😀\ud800'.repeat(Math.ceil(size / 5)).slice(0, size);
      for (const [operation, method, asynchronous] of [['echo', 'echoString', false], ['length', 'stringLength', false], ['async-echo', 'echoStringAsync', true]]) {
        cases.push({ name: `string/${operation}/${size}`, count: sized(asynchronous ? iterations / 10 : iterations, size), warmup: sized(asynchronous ? warmup / 10 : warmup, size), async: asynchronous, input: { utf16_code_units: size, pattern: 'Aé + non-BMP U+1F600 + isolated U+D800' }, call: api => api[method](value) });
      }
    }
    for (const size of [32, 1024, 65536]) {
      const value = Uint8Array.from({ length: size }, (_, i) => i & 255);
      const buffer = Buffer.from(value);
      const owner = new Uint8Array(size + 16);
      owner.set(value, 8);
      const subarray = owner.subarray(8, 8 + size);
      for (const [kind, input] of [['Uint8Array', value], ['Buffer', buffer], ['subarray', subarray]]) {
        cases.push({ name: `bytes/echo/${kind}/${size}`, count: sized(iterations, size), warmup: sized(warmup, size), input: { bytes: size, kind, pattern: 'i & 255', ownership_copies: 2 }, call: api => api.echoBytes(input) });
      }
      const expected = value.reduce((sum, byte) => sum + byte, 0);
      for (const [, api] of implementations) assert.equal(api.sumBytes(value), expected);
      cases.push({ name: `bytes/sum/${size}`, count: sized(iterations, size), warmup: sized(warmup, size), input: { bytes: size, ownership_copies: 1, work: 'sum each byte' }, call: api => api.sumBytes(value) });
      cases.push({ name: `async/bytes-echo/${size}`, count: sized(iterations / 10, size), warmup: sized(warmup / 10, size), async: true, input: { bytes: size, kind: 'Uint8Array', ownership_copies: 2 }, call: api => api.echoBytesAsync(value) });
    }
    const failed = Math.max(50, Math.floor(iterations / 10));
    const failedWarmup = Math.max(10, Math.floor(warmup / 10));
    cases.push(
      { name: 'error/invalid-number', count: failed, warmup: failedWarmup, implementations: ['wasm', 'javascript'], input: "['wrong', 1]", call(api) {
        try { api.add('wrong', 1); } catch (error) { assert(error instanceof TypeError); return 1; }
        throw new Error('Expected TypeError');
      } },
      { name: 'error/dart-business', count: failed, warmup: failedWarmup, implementations: ['wasm', 'javascript'], input: 'StateError("benchmark failure")', call(api) {
        try { api.fail(); } catch (error) { assert(error instanceof Error); return 1; }
        throw new Error('Expected Error');
      } },
      { name: 'async/rejected-business', count: failed, warmup: failedWarmup, async: true, implementations: ['wasm', 'javascript'], input: 'Future failure', async call(api) {
        try { await api.failAsync(); } catch (error) { assert(error instanceof Error); return 1; }
        throw new Error('Expected rejection');
      } },
    );
  }
  let sink = 0;
  const consume = value => {
    if (typeof value === 'number') sink = (sink + value) | 0;
    else if (typeof value === 'string') sink = (sink + value.length) | 0;
    else if (typeof value.length === 'number') {
      const first = value[0];
      sink = (sink + value.length + (typeof first === 'number' ? first : first?.id ?? first?.id0 ?? 0)) | 0;
    }
    else if (value.payload !== undefined) sink = (sink + value.payload.length + (value.payload[0] ?? 0) + value.name.length) | 0;
    else sink = (sink + (value.id ?? value.id0 ?? value.key0?.length ?? 0)) | 0;
  };
  const rows = [];
  for (const benchmark of cases) {
    const available = implementations.filter(([name]) => !benchmark.implementations || benchmark.implementations.includes(name));
    const samples = Object.fromEntries(available.map(([name]) => [name, []]));
    for (const [, api] of available) {
      for (let i = 0; i < benchmark.warmup; i++) consume(benchmark.async ? await benchmark.call(api, i) : benchmark.call(api, i));
    }
    for (let run = 0; run < runs; run++) {
      // Rotate implementation order between samples instead of always timing
      // Wasm first. This is a single process with uncontrolled JIT/GC state.
      for (let index = 0; index < available.length; index++) {
        const [name, api] = available[(index + run) % available.length];
        const start = performance.now();
        if (benchmark.async) {
          for (let i = 0; i < benchmark.count; i++) consume(await benchmark.call(api, i));
        } else {
          for (let i = 0; i < benchmark.count; i++) consume(benchmark.call(api, i));
        }
        samples[name].push((performance.now() - start) * 1e6 / benchmark.count);
      }
    }
    rows.push({ case: benchmark.name, input: benchmark.input, iterations: benchmark.count, warmup: benchmark.warmup, completion: benchmark.async ? 'sequential await per fulfilled/rejected call' : 'synchronous', ns_per_call: Object.fromEntries(Object.entries(samples).map(([name, values]) => [name, summary(values)])) });
  }
  console.log(JSON.stringify({
    group,
    environment: { node: process.version, v8: process.versions.v8, os: `${platform()} ${release()}`, arch: arch(), cpu: cpus()[0]?.model },
    ownership_preflight: (all
      ? 'scalar/bytes: all three implementations; collections/records/batches: Wasm and JavaScript sync independence and async input snapshots'
      : `${group}: Wasm and JavaScript sync independence and async input snapshots`) + (group === 'batch' ? '' : '; packet byte echoes: visible view contents and independently mutable results; owned business-input copies require runtime acceptance'),
    ...(all ? { dart_js_errors: 'omitted: hand-written dart:js_interop entry is not napi error mapping' } : {}),
    notes: 'loop, dispatch, result consumption, validation and ownership copies are included; no concurrent Promise batching',
    sink, cases: rows,
  }));
}

function summary(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const mid = sorted.length >> 1;
  const median = sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  return { samples: values, median, min: sorted[0], max: sorted.at(-1), spread_percent: median ? 100 * (sorted.at(-1) - sorted[0]) / median : 0 };
}
