import assert from 'node:assert/strict';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';
import * as api from '@napi/path';
import {verifyStructures} from './structural_contract.mjs';
import {verifyClasses} from './class_contract.mjs';
import {verifyHierarchy, verifyForeignHierarchy, verifyHierarchyRetention} from './hierarchy_contract.mjs';
import {verifyReferenceViews, verifyForeignReferenceViews, verifyReferenceViewRetention} from './reference_views_contract.mjs';
import {verifyReferences, verifyForeignReferences, verifyReferenceRetention} from './reference_contract.mjs';
import {verifyStructuralReferences, verifyForeignStructuralReferences, verifyStructuralReferenceRetention} from './structural_reference_contract.mjs';
import {verifyMaps, verifyForeignMaps, verifyMapRetention} from './map_contract.mjs';
import {verifyDictionaries, verifyForeignDictionaries, verifyDictionaryRetention} from './dictionary_contract.mjs';
import {verifyValueClasses, verifyForeignValueClasses} from './value_class_contract.mjs';
const {Counter, randomValue, executable, createRequire, bindings, globalThis: exportedGlobal, URL: exportedUrl} = api;

function check() {
  assert.deepEqual([createRequire(), bindings(), exportedGlobal(), exportedUrl()], [1, 2, 3, 4]);
  verifyClasses(api);
  verifyHierarchy(api);
  verifyReferenceViews(api);
  verifyReferences(api);
  verifyStructuralReferences(api);
  verifyMaps(api);
  verifyDictionaries(api);
  verifyValueClasses(api);
  verifyStructures(api);
  assert(randomValue() >= 0);
  assert.equal(executable(), process.execPath);
}
check();
if (isMainThread) {
  const again = await import('@napi/path/native');
  assert.equal(again.Counter, Counter);
  const relative = await import('./node_modules/@napi/path/module.mjs');
  assert.equal(relative.Counter, Counter);
  const independent = await import(import.meta.resolve('@napi/path') + '?independent');
  verifyForeignReferences(api, independent);
  verifyForeignHierarchy(api, independent);
  verifyForeignReferenceViews(api, independent);
  verifyForeignStructuralReferences(api, independent);
  verifyForeignMaps(api, independent);
  verifyForeignDictionaries(api, independent);
  verifyForeignValueClasses(api, independent);
  await verifyReferenceRetention(api);
  await verifyHierarchyRetention(api);
  await verifyReferenceViewRetention(api);
  await verifyStructuralReferenceRetention(api);
  await verifyMapRetention(api);
  await verifyDictionaryRetention(api);
  const foreign = new independent.Counter(9);
  assert.throws(() => Counter.prototype.increment.call(foreign), TypeError);
  assert.equal(foreign.value, 9);
  assert.equal(foreign.increment(), 10);
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
    check();
  }
  console.log('Generated native Counter, properties, ownership and Workers: passed');
} else if (workerData?.hold) {
  parentPort.postMessage('ready');
  setInterval(() => {}, 1000);
}
