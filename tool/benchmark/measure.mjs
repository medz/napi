import assert from 'node:assert/strict';
import {cpus} from 'node:os';
import {pathToFileURL} from 'node:url';

const [entry, kind] = process.argv.slice(2);
global.gc();
const baseline = process.memoryUsage().rss;
const start = performance.now();
const namespace = await import(pathToFileURL(entry));
const api = kind === 'napi-rs' ? namespace.default : namespace;
const importMs = performance.now() - start;
global.gc();
const importRssDelta = process.memoryUsage().rss - baseline;

assert.equal(api.add(2, 3), 5);
const counter = new api.Counter();
assert.equal(counter.increment(), 1);
assert.equal(counter.increment(2), 3);
const input = new Uint8Array([3, 4, 5]);
const copied = api.copyBytes(input);
assert.deepEqual([...input], [3, 4, 5]);
assert.deepEqual([...copied], [2, 4, 5]);
assert.notEqual(copied.buffer, input.buffer);
input[1] = 7;
assert.equal(copied[1], 4);
assert.equal(api.sharedBytes(input), input);
assert.equal(input[0], 2);
assert.deepEqual([...api.allocate(3)], [0, 0, 0]);

let sink = 0;
function sample(operation, calls) {
  const warmup = Math.min(10000, calls);
  for (let i = 0; i < warmup; i++) sink ^= operation(i);
  const rounds = [];
  for (let round = 0; round < 5; round++) {
    global.gc();
    const started = performance.now();
    for (let i = 0; i < calls; i++) sink ^= operation(i);
    rounds.push((performance.now() - started) * 1e6 / calls);
  }
  return rounds;
}
const scalar = sample(i => api.add(i, 1), 100000);
const receiver = new api.Counter();
const method = sample(() => receiver.increment(), 100000);
const binary = {};
for (const size of [64, 4096, 1048576]) {
  const bytes = new Uint8Array(size);
  const calls = size === 1048576 ? 100 : 1000;
  binary[size] = {
    copyNs: sample(() => api.copyBytes(bytes)[0], calls),
    sharedNs: sample(() => api.sharedBytes(bytes)[0], 10000),
    allocateNs: sample(() => api.allocate(size)[0], calls),
  };
}
global.gc();
console.log(JSON.stringify({
  node: process.version, arch: process.arch, cpu: cpus()[0]?.model,
  importMs, importRssDelta,
  rssBytes: process.memoryUsage().rss,
  scalarNs: scalar, methodNs: method, binary, sink,
}));
