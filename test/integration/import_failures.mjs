// Real SDK loader failures: importing the ready-on-import facade must reject.
import assert from 'node:assert/strict';
import { mkdtemp, copyFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
const source = process.argv[2];
const keys = () => Object.getOwnPropertyNames(globalThis).filter(k => k.startsWith('__napi_bootstrap_'));
const before = keys();
const owned = await mkdtemp(join(tmpdir(), 'napi-import-failure-'));
try {
  for (const name of ['index.mjs', 'bootstrap.mjs', 'errors.mjs', 'module.mjs']) {
    await copyFile(join(source, name), join(owned, name));
  }
  await assert.rejects(import(pathToFileURL(join(owned, 'index.mjs')).href), /ENOENT|No such file/i);
  // Distinct module URLs ensure the failed ESM module cache is not reused.
  await copyFile(join(owned, 'index.mjs'), join(owned, 'corrupt.mjs'));
  await copyFile(join(owned, 'bootstrap.mjs'), join(owned, 'corrupt-bootstrap.mjs'));
  const { readFile } = await import('node:fs/promises');
  const facade = await readFile(join(owned, 'corrupt.mjs'), 'utf8');
  await writeFile(join(owned, 'corrupt.mjs'), facade.replace('./bootstrap.mjs', './corrupt-bootstrap.mjs'));
  await writeFile(join(owned, 'module.wasm'), new Uint8Array([0, 1, 2, 3]));
  await assert.rejects(import(pathToFileURL(join(owned, 'corrupt.mjs')).href), WebAssembly.CompileError);
  assert.deepEqual(keys(), before);
} finally {
  await rm(owned, { recursive: true, force: true });
}
console.log('Real SDK missing/corrupt Wasm import failures passed.');
