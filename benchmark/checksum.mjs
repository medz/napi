import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { performance } from 'node:perf_hooks';
import { pathToFileURL } from 'node:url';
import { crc32 } from 'node:zlib';

if (process.argv.length !== 4 || !global.gc) {
  throw new Error('Usage: node --expose-gc benchmark/checksum.mjs <before/module.wasm> <after/module.wasm>');
}
const paths = process.argv.slice(2).map((file) => resolve(file));
const methods = {
  before: (await import(pathToFileURL(paths[0]).href)).checksum,
  after: (await import(pathToFileURL(paths[1]).href)).checksum,
};
const hash = (bytes) => createHash('sha256').update(bytes).digest('hex');
const artifacts = {};
for (const [index, kind] of ['before', 'after'].entries()) {
  assert.match(Function.prototype.toString.call(methods[kind]), /\[native code\]/);
  artifacts[kind] = {};
  for (const file of ['module.wasm', 'module.imports.mjs', 'index.d.ts', 'module.d.wasm.ts', 'package.json']) {
    const bytes = readFileSync(join(dirname(paths[index]), file));
    artifacts[kind][file] = { bytes: bytes.length, sha256: hash(bytes) };
  }
}
assert.equal(artifacts.before['index.d.ts'].sha256, artifacts.after['index.d.ts'].sha256);
const cases = [];
let consumed = 0;
for (const size of [0, 32, 1024, 65536, 1048576]) {
  const bytes = Uint8Array.from({ length: size }, (_, index) => (index * 31 + 7) & 255);
  const inputHash = hash(bytes);
  const file = Object.freeze({ name: 'data.bin', bytes });
  const expected = { name: file.name, byteCount: size, crc32: crc32(bytes) };
  for (const call of Object.values(methods)) assert.deepEqual({ ...call(file) }, expected);
  const calls = size >= 1048576 ? 20 : size >= 65536 ? 100 : size >= 1024 ? 1000 : 5000;
  const warmup = size >= 65536 ? 20 : 200;
  for (let count = 0; count < warmup; count++) {
    consumed ^= methods.before(file).crc32;
    consumed ^= methods.after(file).crc32;
  }
  const samples = [];
  for (let run = 0; run < 14; run++) {
    const order = run % 2 === 0 ? ['before', 'after'] : ['after', 'before'];
    const pair = { run, order };
    for (const kind of order) {
      global.gc();
      const start = performance.now();
      for (let count = 0; count < calls; count++) {
        const result = methods[kind](file);
        consumed ^= result.crc32 ^ result.byteCount;
      }
      pair[kind] = (performance.now() - start) * 1e6 / calls;
    }
    samples.push(pair);
  }
  assert.equal(hash(bytes), inputHash, 'Caller bytes must remain unchanged');
  const median = (values) => {
    values = [...values].sort((a, b) => a - b);
    return (values[6] + values[7]) / 2;
  };
  cases.push({ size, calls, warmup, inputSha256: inputHash, expected, samples,
    mediansNanoseconds: { before: median(samples.map((pair) => pair.before)), after: median(samples.map((pair) => pair.after)) } });
}
console.log(JSON.stringify({ node: process.version, v8: process.versions.v8, artifacts, cases, consumed }, null, 2));
