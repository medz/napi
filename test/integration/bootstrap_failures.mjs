// FAKE loader contract tests. These supplement, never replace, real Wasm tests.
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
const { bootstrap } = await import(pathToFileURL(process.argv[2]).href);
const keys = () => Object.getOwnPropertyNames(globalThis).filter(k => k.startsWith('__napi_bootstrap_'));
const before = keys();
const fake = invokeMain => ({ async instantiate() { return { invokeMain }; } });
await assert.rejects(bootstrap({ async instantiate() { throw new Error('instantiate failed'); } }), /instantiate failed/);
await assert.rejects(bootstrap(fake(() => { throw new Error('main failed'); })), /main failed/);
await assert.rejects(bootstrap(fake(() => {})), /did not register/);
await assert.rejects(bootstrap(fake(key => globalThis[key](null))), /invalid API/);
await assert.rejects(bootstrap(fake(key => { globalThis[key]({}); globalThis[key]({}); })), /registered twice/);
assert.deepEqual(keys(), before);
let leftKey;
let rightKey;
const [left, right] = await Promise.all([
  bootstrap(fake(key => { leftKey = key; globalThis[key]({ side: 'left' }); })),
  bootstrap(fake(key => { rightKey = key; globalThis[key]({ side: 'right' }); })),
]);
assert.notEqual(leftKey, rightKey);
assert.equal(left.side, 'left');
assert.equal(right.side, 'right');
assert.deepEqual(keys(), before);
console.log('Fake loader failure and cleanup contracts passed.');
