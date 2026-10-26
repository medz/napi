'use strict';

const assert = require('node:assert/strict');
const { copyFileSync, readFileSync, statSync, writeFileSync } = require('node:fs');
const { join, resolve } = require('node:path');
const { Worker } = require('node:worker_threads');

const [output, images] = process.argv.slice(2).map(path => resolve(path));
const timeout = setTimeout(() => process.exit(1), 30000);

function machoUuid(bytes) {
  let offset = 32;
  for (let i = 0; i < bytes.readUInt32LE(16); ++i) {
    if (bytes.readUInt32LE(offset) === 0x1b) {
      return bytes.subarray(offset + 8, offset + 24);
    }
    offset += bytes.readUInt32LE(offset + 4);
  }
  throw new Error('Mach-O runtime has no UUID');
}

function counter(path) {
  const { Counter } = require(path);
  const a = new Counter(5);
  const b = new Counter();
  assert.equal(a.value, 5);
  assert.equal(a.increment(), 6);
  assert.equal(a.increment(2), 8);
  assert.equal(b.increment(-3), -3);
  assert.equal(a.value, 8);
  assert.throws(() => Counter(2), TypeError);
  assert.throws(() => Counter.prototype.increment.call({}), TypeError);
  for (const value of [undefined, null, 'x', NaN, Infinity, 1.5, 2 ** 53]) {
    assert.throws(() => new Counter(value), TypeError);
    assert.throws(() => a.increment(value), TypeError);
  }
  assert.equal(a.value, 8);
  const limit = new Counter(Number.MAX_SAFE_INTEGER);
  assert.throws(() => limit.increment(), TypeError);
  assert.equal(limit.value, Number.MAX_SAFE_INTEGER);
  global.gc();
  assert.equal(a.increment(), 9);
}

function worker(path, full) {
  return new Promise((resolve, reject) => {
    let result;
    const worker = new Worker(`
      const { parentPort, workerData } = require('node:worker_threads');
      const addon = require(workerData.path);
      const value = workerData.full
        ? addon.isolateRun(21)
        : new addon.Counter(10).increment(2);
      Promise.resolve(value).then(value => parentPort.postMessage(value));
    `, { eval: true, workerData: { path, full } });
    worker.on('message', value => { result = value; });
    worker.on('error', reject);
    worker.on('exit', code => {
      try {
        assert.equal(code, 0);
        assert.equal(result, full ? 42 : 12);
        resolve();
      } catch (error) { reject(error); }
    });
  });
}

async function main() {
  for (const profile of ['core', 'regexp', 'full']) {
    const directory = join(output, profile);
    const path = join(directory, 'addon.node');
    const image = readFileSync(join(images,
      profile === 'full' ? 'runtime.node' : `runtime-${profile}.node`));
    const addonImage = readFileSync(path);
    assert(process.platform === 'darwin'
      ? machoUuid(addonImage).equals(machoUuid(image))
      : addonImage.subarray(0, image.length).equals(image),
    `${profile}: wrong runtime profile`);
    if (profile !== 'full') {
      counter(path);
      await worker(path, false);
    }
    copyFileSync(join(images, 'NOTICES'), join(directory, 'NOTICES'));
    writeFileSync(join(directory, 'package.json'), JSON.stringify({
      name: `@napi/native-${profile}-smoke`,
      version: '0.0.0',
      main: 'addon.node',
      files: ['addon.node', 'NOTICES'],
    }, null, 2));
    console.log(`${profile}: addon ${statSync(path).size} bytes`);
  }
  const path = join(output, 'full', 'addon.node');
  const addon = require(path);
  assert.equal(addon.answer, 42);
  assert.equal(addon.add(20, 22), 42);
  const platform = { win32: 'windows', darwin: 'macos' }[process.platform] || process.platform;
  assert.equal(JSON.parse(addon.environment()).operatingSystem, platform);
  const file = join(output, 'roundtrip.txt');
  assert.equal(await addon.fileRoundtrip(file, 'Dart 中文'), 'Dart 中文');
  assert.equal(await addon.isolateReadFile(file), 'Dart 中文');
  assert.equal(await addon.httpRoundtrip('hello'), 'Dart HTTP: hello');
  assert.equal(await addon.httpsStatus('https://example.com'), 200);
  assert.equal(await addon.isolateRun(21), 42);
  assert.equal(await addon.isolateSpawn(21), 42);
  await Promise.all(Array.from({ length: 4 }, () => worker(path, true)));
  console.log('full: dart:io, isolates and Workers passed');
}

main().then(() => clearTimeout(timeout), error => {
  console.error(error);
  process.exit(1);
});
