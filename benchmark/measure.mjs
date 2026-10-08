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
  assert.equal(await result, name === 'add' ? 4 : 42);
  console.log(JSON.stringify({ import_ms: imported - start, first_call_ms: performance.now() - imported }));
} else {
  await measure();
}

async function measure() {
  const iterations = Number(args['--iterations']);
  const warmup = Number(args['--warmup']);
  const runs = Number(args['--runs']);
  const wasm = await import(args['--wasm']);
  globalThis.self = globalThis; // dart compile js emits a browser-compatible global.
  await import(args['--dart-js']);
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
  const js = {
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
  };
  // These checks match the valid-input boundary. Copies execute inside the
  // compiled Dart interop entry, so no copy is skipped or counted a third time.
  const dartJs = {
    add: (a, b) => dart.add(number(a), number(b)),
    identityInt: value => integer(dart.identityInt(integer(value))),
    echoString: value => dart.echoString(string(value)),
    stringLength: value => dart.stringLength(string(value)),
    echoBytes: value => dart.echoBytes(bytes(value)),
    sumBytes: value => dart.sumBytes(bytes(value)),
    addAsync: (a, b) => dart.addAsync(number(a), number(b)),
    echoStringAsync: value => dart.echoStringAsync(string(value)),
    echoBytesAsync: value => dart.echoBytesAsync(bytes(value)),
  };
  const implementations = [['wasm', wasm], ['javascript', js], ['dart_javascript', dartJs]];
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
  const sized = (count, size) => Math.max(50, Math.floor(count * 64 / Math.max(64, size)));
  const cases = [
    { name: 'numeric/add', count: iterations, warmup, input: '[i & 1023, 0.25]', call: (api, i) => api.add(i & 1023, 0.25) },
    { name: 'numeric/int-safe53', count: iterations, warmup, input: 'MAX_SAFE_INTEGER - (i & 1023)', call: (api, i) => api.identityInt(Number.MAX_SAFE_INTEGER - (i & 1023)) },
    { name: 'async/add', count: Math.max(50, Math.floor(iterations / 10)), warmup: Math.max(10, Math.floor(warmup / 10)), async: true, input: '[i & 1023, 0.25]', call: (api, i) => api.addAsync(i & 1023, 0.25) },
  ];
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
  let sink = 0;
  const consume = value => {
    if (typeof value === 'number') sink = (sink + value) | 0;
    else if (typeof value === 'string') sink = (sink + value.length) | 0;
    else sink = (sink + value.length + (value[0] || 0)) | 0;
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
    environment: { node: process.version, v8: process.versions.v8, os: `${platform()} ${release()}`, arch: arch(), cpu: cpus()[0]?.model },
    ownership_preflight: 'sync output independence and async input snapshot checked for all three implementations',
    dart_js_errors: 'omitted: hand-written dart:js_interop entry is not napi error mapping',
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
