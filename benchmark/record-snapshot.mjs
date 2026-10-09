import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, stat, writeFile } from 'node:fs/promises';
import { arch, cpus, platform, release } from 'node:os';
import { join } from 'node:path';
import { performance } from 'node:perf_hooks';
import { pathToFileURL } from 'node:url';

const [artifactRoot, output, direction = 'forward', baselineRoot] = process.argv.slice(2);
if (!artifactRoot || !output) throw new Error('Usage: node benchmark/record-snapshot.mjs <after-fixtures> <output.json> [forward|reverse] [before-fixtures]');
assert.ok(['forward', 'reverse'].includes(direction));
const baselineSource = 'e06a091529ea3c1e271e5ed5fec9377198d0f637';
const configuration = {
  sizes: [0, 1, 16, 256], runs: 5, iterations: 20000, workBudget: 65536,
  warmup: 'max(100, floor(calls / 10))',
  keys: 'non-numeric ASCII user_0000, user_0001, ...',
  record: 'own data fields: string name, safe integer age, nullable bool active',
  samples: 'rotate implementation order each sample; reverse variant reverses base order',
};
const artifacts = {};
async function load(root, label = '') {
  const modules = {};
  for (const fixture of ['record-maps', 'batch', 'records']) {
    const dist = join(root, fixture, 'dist');
    const assetKey = label + fixture;
    artifacts[assetKey] = {};
    for (const name of ['module.wasm', 'module.imports.mjs', 'index.d.ts', 'module.d.wasm.ts', 'package.json']) {
      const file = join(dist, name);
      artifacts[assetKey][name] = {
        sha256: createHash('sha256').update(await readFile(file)).digest('hex'),
        bytes: (await stat(file)).size,
      };
    }
    modules[fixture] = await import(pathToFileURL(join(dist, 'module.wasm')));
  }
  return modules;
}
const modules = await load(artifactRoot);
const before = baselineRoot ? await load(baselineRoot, 'before/') : null;

const define = (object, key, value) => Object.defineProperty(object, key, {
  value, enumerable: true, writable: true, configurable: true,
});
function ordinary(value) {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new TypeError('Expected ordinary object');
  const prototype = Object.getPrototypeOf(value);
  if (prototype !== null && prototype !== Object.prototype) throw new TypeError('Expected ordinary object');
}
function descriptor(value, key) {
  const field = Object.getOwnPropertyDescriptor(value, key);
  if (!field || !Object.hasOwn(field, 'value')) throw new TypeError('Expected own data property');
  return field.value;
}
function jsRecord(value, operation) {
  ordinary(value);
  const active = descriptor(value, 'active');
  const age = descriptor(value, 'age');
  const name = descriptor(value, 'name');
  if (active !== null && typeof active !== 'boolean') throw new TypeError('Expected nullable bool');
  if (!Number.isSafeInteger(age)) throw new RangeError('Expected safe integer');
  if (typeof name !== 'string') throw new TypeError('Expected string');
  const result = Object.create(null);
  define(result, 'active', operation === 'normalize' ? active ?? false : active);
  define(result, 'age', operation === 'normalize' ? Math.max(0, age) : age);
  define(result, 'name', operation === 'normalize' ? name.trim() : name);
  return result;
}
function jsList(value, operation) {
  if (!Array.isArray(value)) throw new TypeError('Expected array');
  const snapshot = Array.from({ length: value.length }, (_, index) => descriptor(value, String(index)));
  return snapshot.map(row => jsRecord(row, operation));
}
function jsMap(value, operation) {
  ordinary(value);
  const snapshot = [];
  for (const key of Reflect.ownKeys(value)) {
    const field = Object.getOwnPropertyDescriptor(value, key);
    if (!field?.enumerable) continue;
    if (typeof key !== 'string' || !Object.hasOwn(field, 'value')) throw new TypeError('Expected string data key');
    snapshot.push(key, field.value);
  }
  const result = Object.create(null);
  for (let i = 0; i < snapshot.length; i += 2) define(result, snapshot[i], jsRecord(snapshot[i + 1], operation));
  return result;
}

function makeInput(size) {
  const rows = Array.from({ length: size }, (_, index) => ({
    name: `  User ${index} 😀  `, age: index % 4 === 0 ? -index - 1 : index,
    active: [true, false, null][index % 3],
  }));
  const keys = rows.map((_, index) => `user_${String(index).padStart(4, '0')}`);
  const map = Object.create(null);
  rows.forEach((row, index) => define(map, keys[index], row));
  return { rows, keys, map };
}
function variants(input, operation) {
  const bulk = operation === 'echo' ? 'echoUsers' : 'normalizeUsers';
  const one = operation === 'echo' ? 'echoUser' : 'normalizeUser';
  const list = (name, fn) => ({ name, call: () => fn(input.rows), rows: value => value, consume: value => value[0]?.age ?? 0 });
  const map = (name, fn) => ({ name, call: () => fn(input.map), rows: value => input.keys.map(key => value[key]), consume: value => value[input.keys[0]]?.age ?? 0 });
  const variants = [
    map('wasm_map', modules['record-maps'][bulk]),
    list('wasm_list', modules.batch[bulk]),
    list('wasm_per_row', values => values.map(value => modules.records[one](value))),
    map('javascript_map', value => jsMap(value, operation)),
    list('javascript_list', value => jsList(value, operation)),
    list('javascript_per_row', values => values.map(value => jsRecord(value, operation))),
  ];
  if (before) variants.unshift(
    map('before_map', before['record-maps'][bulk]),
    list('before_list', before.batch[bulk]),
    list('before_per_row', values => values.map(value => before.records[one](value))),
  );
  return direction === 'reverse' ? variants.reverse() : variants;
}

let sink = 0;
const cases = [];
for (const size of configuration.sizes) {
  for (const operation of ['echo', 'normalize']) {
    const input = makeInput(size);
    const expected = input.rows.map(row => operation === 'echo' ? { ...row } : {
      active: row.active ?? false, age: Math.max(0, row.age), name: row.name.trim(),
    });
    const available = variants(input, operation);
    // Correctness and ownership are checked before timing, with fresh inputs.
    for (const variant of available) {
      const result = variant.call();
      const rows = variant.rows(result);
      assert.deepEqual(rows.map(row => ({ ...row })), expected);
      assert.notEqual(result, variant.name.endsWith('map') ? input.map : input.rows);
      if (variant.name.endsWith('map')) assert.equal(Object.getPrototypeOf(result), null);
      for (let index = 0; index < size; index++) {
        assert.equal(Object.getPrototypeOf(rows[index]), null);
        assert.notEqual(rows[index], input.rows[index]);
      }
      if (size) {
        rows[0].age = 100;
        assert.deepEqual(variant.rows(variant.call()).map(row => ({ ...row })), expected);
        assert.equal(input.rows[0].age, -1);
      }
    }
    const calls = Math.min(configuration.iterations, Math.max(128, Math.floor(configuration.workBudget / Math.max(1, size))));
    const warmup = Math.max(100, Math.floor(calls / 10));
    const samples = Object.fromEntries(available.map(({ name }) => [name, []]));
    const orders = [];
    for (const variant of available) {
      for (let i = 0; i < warmup; i++) variant.call();
    }
    for (let run = 0; run < configuration.runs; run++) {
      const order = Array.from({ length: available.length }, (_, index) => available[(index + run) % available.length]);
      orders.push(order.map(({ name }) => name));
      for (const variant of order) {
        let last;
        const start = performance.now();
        for (let i = 0; i < calls; i++) {
          last = variant.call();
          sink = (sink + size + variant.consume(last)) | 0;
        }
        const elapsedMs = performance.now() - start;
        const rows = variant.rows(last);
        assert.deepEqual(rows.map(row => ({ ...row })), expected);
        sink = (sink + rows.length + (rows[0]?.age ?? 0)) | 0;
        samples[variant.name].push(elapsedMs * 1e6 / calls);
      }
    }
    cases.push({ operation, size, calls, warmup, orders,
      ns_per_call: Object.fromEntries(Object.entries(samples).map(([name, values]) => [name, summarize(values)])) });
  }
}
await writeFile(output, JSON.stringify({
  schema: 1, baselineSource, recordedAt: new Date().toISOString(), direction, configuration,
  driver_sha256: createHash('sha256').update(await readFile(new URL(import.meta.url))).digest('hex'),
  comparison: baselineRoot ? 'before_*: baseline artifacts; wasm_*: candidate artifacts; same-process rotated samples' : 'baseline Map/List/per-row comparison',
  environment: { node: process.version, v8: process.versions.v8, os: `${platform()} ${release()}`, arch: arch(), cpu: cpus()[0]?.model },
  artifacts, correctness: 'equal values, fresh outer container and null-prototype records; output mutation leaves input and next call unchanged',
  notes: [
    'Reuse exact installed PR80 fixtures; no compilation or download. Warmed synchronous calls only; no async timer or cold import measurement.',
    'Map/List/one-record fixtures have different export sets; User type and echo/normalize business logic are equivalent.',
    'Per-row controls lack outer-container validation; output is an array and includes JS Array.map dispatch/allocation.',
    'JavaScript references validate only ordinary current-realm valid data shapes, safe integers/string/nullable bool and copy outputs; not the full Proxy/cross-realm/error contract or Dart-owned business-input representation.',
    'Timed loop includes dispatch, validation, copies and per-call consumption of row count plus a known age; correctness traversal is outside timing. JIT/GC/system load are uncontrolled.',
  ], sink, cases,
}, null, 2) + '\n');

function summarize(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const median = sorted[sorted.length >> 1];
  return { samples: values, median, min: sorted[0], max: sorted.at(-1), spread_percent: (sorted.at(-1) - sorted[0]) * 100 / median };
}
