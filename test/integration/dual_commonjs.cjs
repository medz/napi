const assert = require('node:assert/strict');

async function main() {
  for (const name of ['fixture', 'external']) {
    const root = `@napi/dual-${name}`;
    const entry = name === 'external' ? root : `${root}/native`;
    const first = process.argv[2] === 'esm-first'
      ? await import(entry)
      : require(entry);
    const singleton = first.singleton();
    assert.equal(singleton.increment(), 8);
    assert.equal(first.add(3), 5);

    const cjs = require(entry);
    const native = require(`${root}/native`);
    const esm = await import(entry);
    const esmNative = await import(`${root}/native`);
    for (const api of [cjs, native, esm, esmNative]) {
      assert.equal(api.Counter, first.Counter);
      assert.equal(api.singleton(), singleton);
      assert.equal(api.identity(singleton), singleton);
      assert.equal(api.singleton().value, 8);
      assert.equal(api.calls(), 1);
    }
    assert.equal(new cjs.Counter(5).increment(2), 7);
    assert.equal(cjs.add(4), 6);
    assert.equal(esm.calls(), 2);
    assert.equal(await cjs.later(9), 10);
    assert.throws(() => cjs.add('3'), TypeError);
    for (const subpath of ['/wasm', '/module.wasm']) {
      assert.throws(() => require(root + subpath), {code: 'ERR_PACKAGE_PATH_NOT_EXPORTED'});
    }
  }
  assert.throws(() => require('@napi/dual-fixture'), {code: 'ERR_PACKAGE_PATH_NOT_EXPORTED'});
}

main().catch(error => { console.error(error); process.exitCode = 1; });
