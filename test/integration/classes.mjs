import assert from 'node:assert/strict';
import {cp, mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';
import * as api from '@napi/class-fixture';
import {verifyClasses} from './class_contract.mjs';
import {verifyReferences, verifyForeignReferences, verifyReferenceRetention} from './reference_contract.mjs';
import {verifyStructuralReferences, verifyForeignStructuralReferences, verifyStructuralReferenceRetention} from './structural_reference_contract.mjs';
import {verifyMaps, verifyForeignMaps, verifyMapRetention} from './map_contract.mjs';
import {verifyDictionaries, verifyForeignDictionaries, verifyDictionaryRetention} from './dictionary_contract.mjs';

verifyClasses(api);
verifyReferences(api);
verifyStructuralReferences(api);
verifyMaps(api);
verifyDictionaries(api);
if (isMainThread) {
  const again = await import('@napi/class-fixture/module.wasm');
  assert.equal(api.Counter, again.Counter);
  const source = dirname(fileURLToPath(import.meta.resolve('@napi/class-fixture')));
  const temporary = await mkdtemp(join(tmpdir(), 'napi class graph '));
  try {
    // A query on module.wasm alone still shares its imports. Copy the complete
    // graph to exercise truly separate Dart instances and JS class brands.
    const copied = join(temporary, 'copied');
    await cp(source, copied, {recursive: true});
    const independent = await import(pathToFileURL(join(copied, 'module.wasm')));
    assert.notEqual(independent.Counter, api.Counter);
    verifyForeignReferences(api, independent);
    verifyForeignStructuralReferences(api, independent);
    verifyForeignMaps(api, independent);
    verifyForeignDictionaries(api, independent);
    const foreign = new independent.Counter(9);
    assert.throws(() => api.Counter.prototype.increment.call(foreign), TypeError);
    const original = new api.Counter(4);
    assert.throws(() => independent.Counter.prototype.increment.call(original), TypeError);
    assert.equal(foreign.increment(), 10);
    assert.equal(original.increment(), 5);
  } finally {
    await rm(temporary, {recursive: true});
  }
  await verifyRetention();
  await verifyReferenceRetention(api);
  await verifyStructuralReferenceRetention(api);
  await verifyMapRetention(api);
  await verifyDictionaryRetention(api);
  for (let round = 0; round < 2; round++) {
    await Promise.all(Array.from({length: 3}, async (_, i) => {
      const hold = i === 2;
      const worker = new Worker(new URL(import.meta.url), {workerData: {hold}});
      const done = new Promise((resolve, reject) => {
        worker.once('error', reject);
        worker.once('exit', code => code === (hold ? 1 : 0) ? resolve() : reject(Error(`Worker exit ${code}`)));
      });
      if (hold) await new Promise((resolve, reject) => {
        worker.once('message', resolve); worker.once('error', reject);
      });
      if (hold) await worker.terminate();
      await done;
    }));
    verifyClasses(api);
    verifyReferences(api);
    verifyStructuralReferences(api);
    verifyMaps(api);
    verifyDictionaries(api);
  }
  console.log('Generated Wasm classes, independent graph brands, retention and Workers: passed');
} else if (workerData?.hold) {
  parentPort.postMessage('ready');
  setInterval(() => {}, 1000);
}

async function verifyRetention() {
  assert.equal(typeof global.gc, 'function', 'Run the retention fixture with --expose-gc');
  let held = new api.Counter(17);
  const wrapper = new WeakRef(held);
  for (let i = 0; i < 3; i++) {
    await new Promise(resolve => setImmediate(resolve));
    global.gc();
    assert(api.liveCounters() >= 1);
    assert.equal(held.value, 17);
  }
  held = null;
  for (let i = 0; i < 100; i++) {
    await new Promise(resolve => setImmediate(resolve));
    global.gc();
    if (wrapper.deref() === undefined && api.liveCounters() === 0) return;
  }
  assert.fail('Dropped wrappers and their Dart objects must be collectable');
}
