'use strict';

const assert = require('node:assert/strict');
const { copyFileSync, readFileSync, statSync, writeFileSync } = require('node:fs');
const { join, resolve } = require('node:path');
const { Worker } = require('node:worker_threads');
const verifyEnv = require('./env.cjs');
const verifyAnnotatedFunctions = require('./annotated_functions.cjs');
const verifyAnnotatedClasses = require('./annotated_classes.cjs');
const verifyAnnotatedCollections = require('./annotated_collections.cjs');
const verifyAnnotatedCallbacks = require('./annotated_callbacks.cjs');
const verifyAnnotatedFutures = require('./annotated_futures.cjs');
const verifyAnnotatedStreams = require('./annotated_streams.cjs');
const verifyAnnotatedRecords = require('./annotated_records.cjs');
const verifyAnnotatedEnums = require('./annotated_enums.cjs');
const verifyAnnotatedConstants = require('./annotated_constants.cjs');
const verifyAnnotatedJsReferences = require('./annotated_js_references.cjs');
const verifyAnnotatedObjects = require('./annotated_objects.cjs');
const verifyAnnotatedProperties = require('./annotated_properties.cjs');
const verifyAnnotatedGenerics = require('./annotated_generics.cjs');
const verifyAnnotatedDates = require('./annotated_dates.cjs');
const verifyAnnotatedBinaryViews = require('./annotated_binary_views.cjs');
const verifyAnnotatedSimd = require('./annotated_simd.cjs');
const verifyAnnotatedSets = require('./annotated_sets.cjs');
const verifyAnnotatedEnv = require('./annotated_env.cjs');
const verifyAnnotatedInheritance = require('./annotated_inheritance.cjs');
const verifyAnnotatedGenericObjects = require('./annotated_generic_objects.cjs');
const verifyAnnotatedGenericCallbacks = require('./annotated_generic_callbacks.cjs');
const verifyAnnotatedGenericCalls = require('./annotated_generic_calls.cjs');

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

function worker(path) {
  return new Promise((resolve, reject) => {
    let result;
    const worker = new Worker(`
      const { parentPort, workerData } = require('node:worker_threads');
      const addon = require(workerData.path);
      Promise.resolve(addon.isolateRun(21)).then(value => parentPort.postMessage(value));
    `, { eval: true, workerData: { path } });
    worker.on('message', value => { result = value; });
    worker.on('error', reject);
    worker.on('exit', code => {
      try {
        assert.equal(code, 0);
        assert.equal(result, 42);
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
      await verifyEnv(path);
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
  verifyEnv.verifyInitializationFailure(join(output, 'failed', 'addon.node'));
  verifyAnnotatedFunctions(join(output, 'annotated', 'addon.node'));
  await verifyAnnotatedClasses(join(output, 'classes', 'addon.node'));
  verifyAnnotatedCollections(join(output, 'collections', 'addon.node'));
  await verifyAnnotatedCallbacks(join(output, 'callbacks', 'addon.node'));
  await verifyAnnotatedFutures(join(output, 'futures', 'addon.node'));
  await verifyAnnotatedStreams(join(output, 'streams', 'addon.node'));
  await verifyAnnotatedRecords(join(output, 'records', 'addon.node'));
  await verifyAnnotatedEnums(join(output, 'enums', 'addon.node'), [
    join(output, 'enums-package'), join(output, 'enums-assembled'),
  ]);
  await verifyAnnotatedConstants(join(output, 'constants', 'addon.node'), [
    join(output, 'constants-package'), join(output, 'constants-assembled'),
  ]);
  await verifyAnnotatedJsReferences(join(output, 'references', 'addon.node'));
  await verifyAnnotatedObjects(join(output, 'objects', 'addon.node'), [
    join(output, 'objects-package'), join(output, 'objects-assembled'),
  ]);
  await verifyAnnotatedProperties(join(output, 'properties', 'addon.node'), [
    join(output, 'properties-package'), join(output, 'properties-assembled'),
  ]);
  await verifyAnnotatedGenerics(join(output, 'generics', 'addon.node'), join(output, 'generics-package'));
  verifyAnnotatedDates(join(output, 'dates', 'addon.node'));
  verifyAnnotatedBinaryViews(join(output, 'binary-views', 'addon.node'));
  verifyAnnotatedSimd(join(output, 'simd', 'addon.node'));
  verifyAnnotatedSets(join(output, 'sets', 'addon.node'));
  await verifyAnnotatedEnv(join(output, 'env', 'addon.node'));
  await verifyAnnotatedInheritance(
    join(output, 'inheritance', 'addon.node'), join(output, 'inheritance-package'));
  await verifyAnnotatedGenericObjects(join(output, 'generic-objects', 'addon.node'));
  await verifyAnnotatedGenericCallbacks(join(output, 'generic-callbacks', 'addon.node'));
  await verifyAnnotatedGenericCalls(join(output, 'generic-calls', 'addon.node'));
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
  await Promise.all(Array.from({ length: 4 }, () => worker(path)));
  console.log('full: dart:io, isolates and Workers passed');
}

main().then(() => clearTimeout(timeout), error => {
  console.error(error);
  process.exit(1);
});
