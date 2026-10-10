import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { arch, cpus, platform, release } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { pathToFileURL } from 'node:url';
import { runInNewContext } from 'node:vm';

const usage = `Usage: node benchmark/bytes.mjs <module.wasm> [options]
  --runs <count>        Samples per route (default: 12)
  --iterations <count> Maximum calls per sample (default: 2000)
  --warmup <count>     Maximum warmup calls per route (default: 200)
  --budget <bytes>     Copy-work scaling target per sample (default: 16777216)
Prints JSON; reuses the supplied artifact without compiling or downloading.
Counts scale with payload bytes and leaf count, with a 30-call floor bounded
by --iterations. The budget is a scaling target, not a hard memory limit.
No timing assertions are made.`;
const args = process.argv.slice(2);
if (args.includes('--help')) {
  console.log(usage);
  process.exit(0);
}
const configuration = { runs: 12, iterations: 2000, warmup: 200, budget: 16 * 1024 * 1024 };
const suppliedPath = args.shift();
if (!suppliedPath || suppliedPath.startsWith('--')) throw new Error(usage);
while (args.length) {
  const option = args.shift();
  const key = option.slice(2);
  if (!option.startsWith('--') || !Object.hasOwn(configuration, key)) throw new Error(`Unknown option ${option}\n${usage}`);
  const value = args.shift();
  if (!value || !/^[0-9]+$/.test(value) || !Number.isSafeInteger(Number(value)) || Number(value) < 1) {
    throw new Error(`${option} requires a positive safe integer`);
  }
  configuration[key] = Number(value);
}

const modulePath = resolve(suppliedPath);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const artifacts = {};
for (const file of ['module.wasm', 'module.imports.mjs', 'index.d.ts', 'module.d.wasm.ts', 'package.json']) {
  const bytes = readFileSync(file === 'module.wasm' ? modulePath : join(dirname(modulePath), file));
  artifacts[file] = { bytes: bytes.length, sha256: hash(bytes) };
}
const api = await import(pathToFileURL(modulePath).href);
for (const name of ['echoBytes', 'echoByteList', 'echoBytesAsync', 'echoByteListAsync']) {
  assert.equal(typeof api[name], 'function', name);
  assert.match(Function.prototype.toString.call(api[name]), /\[native code\]/, name);
}

const tag = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), Symbol.toStringTag).get;
function copyBytes(value) {
  if (value === null || typeof value !== 'object' || Reflect.apply(tag, value, []) !== 'Uint8Array') {
    throw new TypeError('Expected Uint8Array');
  }
  return new Uint8Array(value);
}
function readByteList(value) {
  if (!Array.isArray(value)) throw new TypeError('Expected Array');
  const snapshot = Array.from({ length: value.length }, (_, index) => {
    const field = Object.getOwnPropertyDescriptor(value, String(index));
    if (!field || !Object.hasOwn(field, 'value')) throw new TypeError('Expected own data index');
    return field.value;
  });
  return snapshot.map(copyBytes);
}
const sync = [
  { name: 'wasm_batch', call: api.echoByteList },
  { name: 'wasm_per_chunk', call: values => values.map(api.echoBytes) },
  { name: 'javascript_batch', call: values => readByteList(values).map(copyBytes) },
];
const asynchronous = [
  { name: 'wasm_batch', call: api.echoByteListAsync },
  { name: 'wasm_per_chunk', call: values => Promise.all(values.map(api.echoBytesAsync)) },
  { name: 'javascript_batch', call: async values => {
    const owned = readByteList(values);
    await Promise.resolve();
    return owned.map(copyBytes);
  } },
];
const permutations = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]];
function inputHash(input) {
  const digest = createHash('sha256');
  for (const bytes of input) digest.update(bytes);
  return digest.digest('hex');
}
function expectedBytes(input) {
  return Array.from(input, bytes => new Uint8Array(bytes));
}
function checkOutput(output, expected, input) {
  assert(Array.isArray(output));
  assert.equal(output.length, expected.length);
  assert.notEqual(output, input);
  const buffers = new Set();
  const sourceBuffers = new Set(Array.from(input, source => source.buffer));
  for (let index = 0; index < output.length; index++) {
    assert(output[index] instanceof Uint8Array);
    assert.deepEqual(output[index], expected[index]);
    assert.equal(output[index].byteOffset, 0);
    assert.equal(output[index].buffer.byteLength, expected[index].length);
    assert(!buffers.has(output[index].buffer), 'Each result element owns separate storage');
    buffers.add(output[index].buffer);
    assert(!sourceBuffers.has(output[index].buffer), 'Results must not share caller storage');
  }
}
function consume(output) {
  let value = output.length;
  for (const bytes of output) value += (bytes[0] ?? 0) + (bytes.at(-1) ?? 0);
  return value;
}

const preflight = [];
const backing = Uint8Array.of(90, 91, 3, 4, 5, 92);
const repeated = Uint8Array.of(7, 8, 9);
const validInputs = [
  [],
  [Buffer.from([0, 128, 255]), backing.subarray(2, 5), new Uint8Array(0)],
  runInNewContext('[new Uint8Array([17, 18]), new Uint8Array([19])]'),
  Object.freeze([repeated, repeated]),
];
for (const [mode, routes] of [['sync', sync], ['async', asynchronous]]) {
  for (const route of routes) {
    for (const input of validInputs) {
      const expected = expectedBytes(input);
      const beforeHash = inputHash(input);
      const pending = route.call(input);
      if (mode === 'async') assert(pending instanceof Promise);
      const output = mode === 'async' ? await pending : pending;
      checkOutput(output, expected, input);
      if (output[0]?.length) output[0][0] ^= 255;
      if (input.length === 2 && input[0] === input[1]) assert.deepEqual(output[1], expected[1]);
      assert.equal(inputHash(input), beforeHash, 'Output mutation must not change caller bytes');
      checkOutput(mode === 'async' ? await route.call(input) : route.call(input), expected, input);
    }
    preflight.push(`${mode}/${route.name}: Buffer, offset and cross-realm views; empty/repeated inputs; independent output storage and caller bytes`);
  }
}
for (const [mode, routes] of [['sync', sync], ['async', asynchronous]]) {
  for (const route of routes.filter(route => route.name !== 'wasm_per_chunk')) {
    let getters = 0;
    const accessor = [Uint8Array.of(1)];
    Object.defineProperty(accessor, '0', { get() { getters++; throw new Error('Index getter must not run'); } });
    const inherited = new Array(1);
    Object.setPrototypeOf(inherited, { 0: Uint8Array.of(1) });
    for (const input of [new Array(1), inherited, accessor, new Uint8Array(1), [new Uint16Array(1)], [null], [undefined]]) {
      if (mode === 'async') {
        const pending = route.call(input);
        assert(pending instanceof Promise);
        await assert.rejects(pending, TypeError);
      } else {
        assert.throws(() => route.call(input), TypeError);
      }
    }
    assert.equal(getters, 0);
    preflight.push(`${mode}/${route.name}: rejects holes, inherited/accessor indices, non-Arrays and invalid byte brands without invoking the index getter`);
  }
}
for (const route of asynchronous) {
  const first = Uint8Array.of(5, 6, 7);
  const second = Uint8Array.of(8, 9);
  const input = [first, first, second];
  const expected = expectedBytes(input);
  const pending = route.call(input);
  assert(pending instanceof Promise);
  first.fill(99);
  second.fill(88);
  structuredClone(first.buffer, { transfer: [first.buffer] });
  assert.equal(first.byteLength, 0);
  input.push(Uint8Array.of(100));
  input[0] = Uint8Array.of(101);
  checkOutput(await pending, expected, input);
  preflight.push(`async/${route.name}: copies storage and membership before Promise return; later mutation and transfer do not change results`);
}

function summarize(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const middle = sorted.length >> 1;
  const median = sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
  return { samples: values, min: sorted[0], median, max: sorted.at(-1), spread_percent: (sorted.at(-1) - sorted[0]) * 100 / median };
}
const definitions = [{ chunks: 0, bytesPerChunk: 0, family: 'empty' }];
for (const chunks of [1, 16, 256]) {
  for (const bytesPerChunk of [0, 32, 1024]) definitions.push({ chunks, bytesPerChunk, family: 'per_chunk' });
}
for (const chunks of [1, 16, 256]) definitions.push({ chunks, bytesPerChunk: 65536 / chunks, family: 'fixed_total' });
for (const chunks of [0, 1, 16, 256]) definitions.push({ chunks, bytesPerChunk: 1024, family: 'async', asynchronous: true });
let sink = 0;
const cases = [];
for (const [caseIndex, definition] of definitions.entries()) {
  const { chunks, bytesPerChunk } = definition;
  const input = Array.from({ length: chunks }, (_, chunk) => Uint8Array.from(
    { length: bytesPerChunk }, (_, offset) => (chunk * 17 + offset * 31 + 7) & 255,
  ));
  const expected = expectedBytes(input);
  const beforeHash = inputHash(input);
  const totalBytes = chunks * bytesPerChunk;
  const workPerCall = Math.max(1, totalBytes * 2, chunks * 64);
  const calls = Math.min(configuration.iterations, Math.max(Math.min(30, configuration.iterations), Math.floor(configuration.budget / workPerCall)));
  const warmup = Math.min(configuration.warmup, calls);
  const routes = definition.asynchronous ? asynchronous : sync;
  for (const route of routes) {
    checkOutput(definition.asynchronous ? await route.call(input) : route.call(input), expected, input);
    for (let count = 0; count < warmup; count++) {
      sink = (sink + consume(definition.asynchronous ? await route.call(input) : route.call(input))) | 0;
    }
  }
  const samples = Object.fromEntries(routes.map(({ name }) => [name, []]));
  const orders = [];
  for (let run = 0; run < configuration.runs; run++) {
    const order = permutations[(run + caseIndex) % permutations.length].map(index => routes[index]);
    orders.push(order.map(({ name }) => name));
    for (const route of order) {
      let last;
      const start = performance.now();
      if (definition.asynchronous) {
        for (let count = 0; count < calls; count++) {
          last = await route.call(input);
          sink = (sink + consume(last)) | 0;
        }
      } else {
        for (let count = 0; count < calls; count++) {
          last = route.call(input);
          sink = (sink + consume(last)) | 0;
        }
      }
      samples[route.name].push((performance.now() - start) * 1e6 / calls);
      checkOutput(last, expected, input);
    }
  }
  assert.equal(inputHash(input), beforeHash, 'All timed routes must leave input bytes unchanged');
  cases.push({ ...definition, totalBytes, input_sha256: beforeHash, calls, warmup, workPerCall, orders,
    ns_per_batch: Object.fromEntries(Object.entries(samples).map(([name, values]) => [name, summarize(values)])),
    ns_per_chunk: chunks === 0 ? null : Object.fromEntries(Object.entries(samples).map(([name, values]) => [name, summarize(values.map(value => value / chunks))])),
  });
}
console.log(JSON.stringify({
  schema: 1, recordedAt: new Date().toISOString(), modulePath, configuration,
  driver_sha256: hash(readFileSync(new URL(import.meta.url))),
  environment: { node: process.version, v8: process.versions.v8, os: `${platform()} ${release()}`, arch: arch(), cpu: cpus()[0]?.model },
  artifacts, preflight, input_pattern: '(chunkIndex * 17 + byteOffset * 31 + 7) & 255',
  notes: [
    'One supplied compiled package; no rebuild, download, packing, import-time measurement or timing gate.',
    'Batch routes validate own Array data indices and copy each byte input and output. Per-chunk routes use Array.map/native calls without outer Array validation.',
    'JavaScript covers the measured dense own-data Arrays and byte brands, with real input/output copies. Semantic ownership boundaries match; physical allocation and Dart-owned representations differ. It is not the complete Proxy/error contract.',
    'Async batches return one Promise; repeated native Futures use Promise.all; JavaScript copies all input before one await. Scheduling and Promise counts differ; these are completed application routes, not equivalent scheduler microbenchmarks.',
    'Every six samples use all route-order permutations. Other run counts may leave an incomplete final cycle. All routes consume identical output length and first/last bytes of every element inside timing; full correctness checks are outside timing.',
    'Counts scale by max(1, two payload-copy byte counts, 64 units per leaf) with a floor bounded by iterations; work units are a sampling heuristic, not a physical allocation measurement.',
    'JIT, garbage collection, filesystem caches and system load are uncontrolled. Raw samples and spreads do not establish an application speed guarantee.',
    'Fixture export sets affect package size; supplied artifact sizes do not isolate the incremental cost of byte List support.',
  ], sink, cases,
}, null, 2));
