import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { arch, cpus, platform, release } from 'node:os';
import { join, resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { pathToFileURL } from 'node:url';

const [beforePath, afterPath, direction = 'forward', mode] = process.argv.slice(2);
const emptyOnly = mode === '--empty';
if (!beforePath || !afterPath || !['forward', 'reverse'].includes(direction) ||
    (mode !== undefined && !emptyOnly) || process.argv.length > 6) {
  throw new Error('Usage: node benchmark/list-scalars.mjs <before/collections/dist> <after/collections/dist> [forward|reverse] [--empty]');
}
const artifacts = {};
const phases = [];
for (const [name, path] of [['before', beforePath], ['after', afterPath]]) {
  artifacts[name] = {};
  for (const file of ['module.wasm', 'module.imports.mjs', 'index.d.ts', 'module.d.wasm.ts', 'package.json']) {
    const bytes = readFileSync(join(path, file));
    artifacts[name][file] = {bytes: bytes.length, sha256: createHash('sha256').update(bytes).digest('hex')};
  }
  const api = await import(pathToFileURL(resolve(path, 'module.wasm')));
  for (const key of ['listInt', 'listIntAsync']) assert.match(Function.prototype.toString.call(api[key]), /\[native code\]/);
  phases.push({name, api});
}
for (const file of ['module.wasm', 'index.d.ts', 'module.d.wasm.ts', 'package.json']) assert.deepEqual(artifacts.before[file], artifacts.after[file]);
if (direction === 'reverse') phases.reverse();
let sink = 0;
const cases = [];
function consume(output) {
  let result = output.length;
  for (const value of output) result += value;
  return result;
}
function check(output, input) {
  assert.deepEqual(output, input);
  assert.notEqual(output, input);
}
function summarize(samples) {
  const sorted = [...samples].sort((a, b) => a - b);
  const median = sorted[sorted.length >> 1];
  return {samples, min: sorted[0], median, max: sorted.at(-1), spread_percent: (sorted.at(-1) - sorted[0]) * 100 / median};
}
for (const asynchronous of [false, true]) {
  for (const size of emptyOnly ? [0] : [0, 1, 16, 256]) {
    const input = Array.from({length: size}, (_, index) => index & 255);
    const inputHash = createHash('sha256').update(JSON.stringify(input)).digest('hex');
    const calls = emptyOnly ? (asynchronous ? 100000 : 1000000) : asynchronous ? Math.max(256, Math.floor(8192 / Math.max(1, size)))
      : Math.min(100000, Math.max(512, Math.floor(262144 / Math.max(1, size))));
    const warmup = Math.max(100, Math.floor(calls / 10));
    const key = asynchronous ? 'listIntAsync' : 'listInt';
    const samples = Object.fromEntries(phases.map(({name}) => [name, []]));
    for (const {api} of phases) {
      check(asynchronous ? await api[key](input) : api[key](input), input);
      for (let index = 0; index < warmup; index++) sink ^= consume(asynchronous ? await api[key](input) : api[key](input));
    }
    const orders = [];
    for (let run = 0; run < (emptyOnly ? 9 : 7); run++) {
      const order = run % 2 ? [...phases].reverse() : phases;
      orders.push(order.map(({name}) => name));
      for (const {name, api} of order) {
        let output;
        const start = performance.now();
        if (asynchronous) {
          for (let index = 0; index < calls; index++) sink ^= consume(output = await api[key](input));
        } else {
          for (let index = 0; index < calls; index++) sink ^= consume(output = api[key](input));
        }
        samples[name].push((performance.now() - start) * 1e6 / calls);
        check(output, input);
      }
    }
    assert.equal(createHash('sha256').update(JSON.stringify(input)).digest('hex'), inputHash);
    cases.push({asynchronous, size, calls, warmup, input_sha256: inputHash, orders, ns_per_call: Object.fromEntries(Object.entries(samples).map(([name, values]) => [name, summarize(values)]))});
  }
}
console.log(JSON.stringify({schema:1, direction, empty_only:emptyOnly, driver_sha256:createHash('sha256').update(readFileSync(new URL(import.meta.url))).digest('hex'),
  environment:{node:process.version,v8:process.versions.v8,os:`${platform()} ${release()}`,arch:arch(),cpu:cpus()[0]?.model},artifacts,
  notes:['Same-process interleaved native phases; independent process reverses initial order. No compile/download/packing, timing gate or explicit GC.',
    'Safe-int List echo, dense own data indices and independent input/output Arrays. Both routes consume every element identically; assertions outside timing. Async calls complete sequentially.',
    'JIT, GC and system load are uncontrolled. Counts and raw samples do not establish application speed or individual operation attribution.'],sink,cases},null,2));
