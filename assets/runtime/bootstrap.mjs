// Project-owned bootstrap. module.mjs is the unchanged Dart SDK loader.
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { compile } from './module.mjs';

export async function bootstrap(compiled) {
  const instance = await compiled.instantiate();
  let key;
  do { key = `__napi_bootstrap_${randomUUID()}`; }
  while (Object.hasOwn(globalThis, key));
  let api;
  let registered = false;
  Object.defineProperty(globalThis, key, {
    configurable: true,
    enumerable: false,
    writable: false,
    value(value) {
      if (registered) throw new Error('Dart bootstrap registered twice');
      if (value === null || typeof value !== 'object') {
        throw new TypeError('Dart bootstrap registered an invalid API');
      }
      api = value;
      registered = true;
    },
  });
  try {
    instance.invokeMain(key);
    if (!registered) throw new Error('Dart bootstrap did not register its API');
    return api;
  } finally {
    delete globalThis[key];
  }
}

export async function initialize() {
  const bytes = await readFile(new URL('./module.wasm', import.meta.url));
  const compiled = await compile(bytes);
  return bootstrap(compiled);
}
