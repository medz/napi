import assert from 'node:assert/strict';
import {cpSync, mkdtempSync, readFileSync, rmSync, unlinkSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {spawnSync} from 'node:child_process';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';

async function check(name, selected) {
  const [root, native, wasm, direct] = await Promise.all([
    import(name), import(name + '/native'), import(name + '/wasm'),
    import(name + '/module.wasm'),
  ]);
  assert.equal(root.Counter, (selected === 'native' ? native : wasm).Counter);
  assert.equal(root.add, (selected === 'native' ? native : wasm).add);
  assert.equal(wasm.Counter, direct.Counter);
  assert.equal((await import(name)).singleton(), root.singleton());
  assert.notEqual(native.Counter, wasm.Counter);
  assert.notEqual(native.singleton(), wasm.singleton());
  for (const current of [native, wasm]) {
    const original = Object.freeze({label: 'row', values: Object.freeze([1, 2])});
    const row = current.appendRow(original);
    assert.deepEqual(row, {label: 'row', values: [1, 2, 3]});
    assert.notEqual(row, original);
    assert.notEqual(row.values, original.values);
    row.values.push(4);
    assert.deepEqual(original, {label: 'row', values: [1, 2]});
    current.reset();
    assert.equal(current.add(4), 6);
    assert.equal(current.add(4, 3), 7);
    assert.equal(current.calls(), 2);
    assert.throws(() => current.add(1.5), RangeError);
    assert.throws(() => current.add(), TypeError);
    assert.throws(() => current.add(undefined), TypeError);
    assert.equal(current.calls(), 2);
    assert.equal(current.format('A'), 'A雪');
    assert.equal(current.format('A', {suffix:'𐀀'}), 'A𐀀');
    assert.equal(current.reset(), undefined);
    assert.throws(() => current.fail(), /dual-failure/);
    const counter = new current.Counter();
    assert.equal(counter.increment(), 2);
    assert.equal(current.identity(counter), counter);
    assert.equal(current.Counter.seed(9).value, 9);
    assert.equal(current.invoke(x => x + 3, 4), 7);
    const exact = {sentinel: true};
    assert.throws(() => current.invoke(() => { throw exact; }, 1), e => e === exact);
    assert.equal(await current.later(8), 9);
    const items = [];
    for await (const value of current.sequence(4)) items.push(value);
    assert.deepEqual(items, [4, 5]);
    const resource = new current.Resource(6);
    const pending = resource.read();
    const closed = resource.close();
    assert.equal(resource.close(), closed);
    assert.equal(await pending, 6);
    await closed;
    await assert.rejects(resource.read(), /closing|closed/i);
    const streamResource = new current.Resource(9);
    const values = [];
    for await (const value of streamResource.values()) values.push(value);
    assert.deepEqual(values, [9, 10]);
    await streamResource.close();
    assert.equal(current.cleanups(), 2);
    assert.equal(current.structuralDefaults(), true);
    assert.equal(current.structuralDefaults(undefined, undefined, undefined, undefined), true);
    assert.equal(current.structuralDefaults([], undefined), false);
    assert.equal(current.structuralDefaults(undefined, new Map()), false);
    const beforeDefaults = current.calls();
    assert.throws(() => current.structuralDefaults(null), TypeError);
    assert.throws(() => current.structuralDefaults(undefined, new Map([['a', ['bad']]])), TypeError);
    assert.equal(current.calls(), beforeDefaults);
    for (const options of [undefined, {}, {numbers: undefined, wide: undefined}]) {
      assert.equal(current.namedDefaults(options), true);
    }
    assert.equal(current.namedDefaults({numbers: [1]}), false);
    const base = new current.DefaultBase();
    assert.equal(base.original, true);
    assert.equal(current.DefaultBase.named({value: undefined}).original, true);
    assert.equal(new current.DefaultBase([]).original, false);
    const child = new current.DefaultChild();
    assert.equal(child.check(), false);
    assert.equal(child.check({value: undefined}), false);
    assert.equal(current.DefaultBase.prototype.check.call(child, {}), true);
    assert.equal(current.DefaultBase.prototype.check.call(child, {value: []}), false);
    assert.equal(await child.later(), true);
    assert.deepEqual(await Array.fromAsync(child.sequence()), [true]);
    const snapshot = base.snapshot();
    snapshot[0] = 9;
    assert.deepEqual(base.snapshot(), [1, 2]);
    assert.throws(() => current.identity({value: 4}), TypeError);
  }
  assert.throws(() => native.identity(wasm.singleton()), TypeError);
  assert.throws(() => wasm.identity(native.singleton()), TypeError);
  native.reset(); wasm.reset();
  native.add(1);
  assert.equal(wasm.calls(), 0);
}

if (!isMainThread) {
  if (workerData.terminate) {
    const bindings = await import(workerData.name);
    const resource = new bindings.Resource(4);
    void resource.read(60000);
    parentPort.postMessage('ready');
  } else {
    await check(workerData.name, workerData.selected);
    parentPort.postMessage('done');
  }
} else {
  await check('@napi/dual-fixture', 'wasm');
  await check('@napi/dual-external', 'native');
  for (const [name, selected] of [
    ['@napi/dual-fixture', 'wasm'], ['@napi/dual-external', 'native'],
  ]) {
    const worker = new Worker(new URL(import.meta.url), {workerData: {name, selected}});
    await new Promise((resolve, reject) => {
      worker.once('error', reject);
      worker.once('exit', code => code === 0 ? resolve() : reject(new Error('worker ' + code)));
    });
    const terminated = new Worker(new URL(import.meta.url), {workerData: {name, terminate:true}});
    await new Promise((resolve, reject) => {
      terminated.once('error', reject);
      terminated.once('message', resolve);
    });
    await terminated.terminate();
  }

  const originals = [
    ['@napi/dual-fixture', 'wasm'], ['@napi/dual-external', 'native'],
  ];
  for (const [name, selected] of originals) {
    const installed = dirname(dirname(fileURLToPath(import.meta.resolve(name + '/native'))));
    const parent = mkdtempSync(join(tmpdir(), 'dual relocated 雪 '));
    const copied = join(parent, 'node_modules', '@napi', 'copy');
    try {
      cpSync(installed, copied, {recursive: true});
      const run = source => {
        const result = spawnSync(process.execPath, ['--input-type=module', '-e', source],
          {cwd: parent, encoding: 'utf8'});
        assert.equal(result.status, 0, result.stdout + result.stderr);
      };
      run(`import assert from 'node:assert/strict';
        const a = await import('@napi/copy');
        const b = await import(${JSON.stringify(pathToFileURL(join(installed,
          selected === 'wasm' ? 'wasm/module.wasm' : 'native/module.mjs')).href)});
        assert.notEqual(a.Counter, b.Counter);
        assert.throws(() => a.identity(b.singleton()), TypeError);
        assert.equal(a.add(1), 3);`);
      const runtime = JSON.parse(readFileSync(join(copied, 'native/runtime.json'))).runtime;
      for (const [backend, file] of [['native','bridge.node'], ['native',runtime],
        ['native','module.aot'], ['wasm','host.mjs'], ['wasm','module.wasm']]) {
        const bad = join(copied, backend, file);
        unlinkSync(bad);
        run(`import assert from 'node:assert/strict';
          const name = '@napi/copy';
          await assert.rejects(import(name + '/${backend}'));
          const other = await import(name + '/${backend === 'native' ? 'wasm' : 'native'}');
          assert.equal(other.add(2), 4);
          ${selected === backend ? "await assert.rejects(import(name));" :
            "assert.equal((await import(name)).Counter, other.Counter);"}`);
        cpSync(join(installed, backend, file), bad);
      }
    } finally { rmSync(parent, {recursive:true, force:true}); }
  }
  console.log('Dual package entries, isolation, failures, resources and Workers: passed');
}
