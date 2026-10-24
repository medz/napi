const assert = require('node:assert/strict');

async function main() {
  const first = process.argv[2] === 'esm-first'
    ? await import('@napi/platform-fixture')
    : require('@napi/platform-fixture');
  const singleton = first.singleton();
  assert.equal(singleton.increment(), 8);
  assert.equal(first.add(3), 5);

  const cjs = require('@napi/platform-fixture');
  const native = require('@napi/platform-fixture/native');
  const esm = await import('@napi/platform-fixture');
  const esmNative = await import('@napi/platform-fixture/native');
  for (const api of [cjs, native, esm, esmNative]) {
    assert.equal(api.Counter, first.Counter);
    assert.equal(api.singleton(), singleton);
    assert.equal(api.singleton().value, 8);
    assert.equal(api.calls(), 1);
  }
  assert.equal(new cjs.Counter(5).increment(2), 7);
  assert.equal(cjs.add(4), 6);
  assert.equal(esm.calls(), 2);
  assert.throws(() => cjs.add('3'), TypeError);
  assert.throws(() => require('@napi/platform-fixture/wasm'), {code: 'ERR_PACKAGE_PATH_NOT_EXPORTED'});
}

main().catch(error => { console.error(error); process.exitCode = 1; });
