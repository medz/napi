import assert from 'node:assert/strict';
import {cpSync, mkdtempSync, readFileSync, rmSync, unlinkSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {dirname, join} from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {spawnSync} from 'node:child_process';
import {Worker, isMainThread, parentPort, workerData} from 'node:worker_threads';

async function check(name, selected) {
  let onSignalRead;
  const aborted = Object.getOwnPropertyDescriptor(AbortSignal.prototype, 'aborted');
  let loaded;
  Object.defineProperty(AbortSignal.prototype, 'aborted', {...aborted, get() {
    const callback = onSignalRead;
    onSignalRead = undefined;
    callback?.();
    return Reflect.apply(aborted.get, this, []);
  }});
  try {
    loaded = await Promise.all([
      import(name), import(name + '/native'), import(name + '/wasm'),
      import(name + '/module.wasm'),
    ]);
  } finally { Object.defineProperty(AbortSignal.prototype, 'aborted', aborted); }
  const [root, native, wasm, direct] = loaded;
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
      assert.equal(current.namedDefaults(options), true,
        `${name} ${current === native ? 'native' : 'wasm'} named defaults`);
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
    assert.equal(current.objectDefaults(), true);
    assert.equal(current.objectDefaults(...Array(6).fill(undefined)), true);
    const defaultToken = current.objectDefaultToken();
    assert.equal(current.objectDefaultToken(undefined), defaultToken);
    const suppliedToken = new current.DefaultToken(7);
    assert.equal(current.objectDefaultToken(suppliedToken), suppliedToken);
    assert.equal(current.objectDefaults(suppliedToken), false);
    assert.equal(current.objectDefaults(undefined, {}), false);
    assert.equal(current.objectDefaults(undefined, undefined, []), false);
    assert.equal(current.objectDefaults(undefined, undefined, undefined, new Map()), false);
    const beforeObjects = current.calls();
    assert.throws(() => current.objectDefaults(null), TypeError);
    assert.throws(() => current.objectDefaults(undefined, undefined, [{value: 'bad'}]), TypeError);
    assert.throws(() => current.objectDefaults(undefined, undefined, undefined,
      new Map([['token', {value: 7}]])), TypeError);
    assert.equal(current.calls(), beforeObjects);
    assert.equal(current.objectDefaultAfter(), 10);
    assert.equal(current.objectDefaultAfter(undefined, 0), 7);
    assert.equal(current.objectDefaultAfter(new current.DefaultToken(5), 0), 5);
    for (const options of [undefined, {}, {token: undefined}, {token: defaultToken}]) {
      assert.equal(current.namedObjectDefault(options), true);
    }
    assert.equal(current.namedObjectDefault({token: null}), false);
    assert.equal(current.namedObjectDefault({token: suppliedToken}), false);
    assert.throws(() => current.namedObjectDefault({token: {value: 7}}), TypeError);
    const defaultValue = current.objectDefaultValue();
    assert.deepEqual(defaultValue, {value: 9});
    defaultValue.value = 20;
    assert.deepEqual(current.objectDefaultValue(undefined), {value: 9});
    assert.equal(current.valueFieldDefault({}), true);
    assert.equal(current.valueFieldDefault({token: undefined}), true);
    assert.equal(current.valueFieldDefault({token: suppliedToken}), false);
    assert.throws(() => current.valueFieldDefault({token: null}), TypeError);
    assert.equal(current.genericObjectDefault(), true);
    assert.equal(current.genericObjectDefault(undefined), true);
    assert.equal(current.genericObjectDefault(new current.DefaultIntBox(13)), false);
    assert.equal(current.factoryObjectDefault(), true);
    assert.equal(current.factoryObjectDefault(undefined), true);
    assert.equal(current.factoryObjectDefault(new current.DefaultProjection(17)), false);
    assert.equal(current.DefaultBase.object().original, true);
    assert.equal(current.DefaultBase.namedObject({value: undefined}).original, true);
    assert.equal(child.checkObject({value: undefined}), true);
    assert.equal(child.checkObject({value: suppliedToken}), false);
    assert.equal(await child.laterObject(), true);
    assert.equal(await child.laterObject({}), false);
    assert.deepEqual(await Array.fromAsync(child.sequenceObject(undefined)), [true]);
    const origin = current.originPointDefault();
    const staticOrigin = current.staticObjectDefault();
    assert.equal(origin.value, 31);
    assert.equal(origin.checksum, 39);
    assert.equal(staticOrigin.value, 32);
    assert.equal(staticOrigin.checksum, 41);
    assert.equal(current.originPointDefault(undefined), origin);
    assert.equal(current.originPointDefault(origin), origin);
    assert.equal(current.staticObjectDefault(undefined), staticOrigin);
    assert.equal(current.namedContainerDefaults(), true);
    assert.equal(current.namedContainerDefaults(undefined, undefined, undefined), true);
    assert.equal(current.namedContainerDefaults([origin]), false);
    assert.equal(current.namedValueFieldDefault({}), true);
    assert.equal(current.namedValueFieldDefault({point: undefined}), true);
    assert.equal(current.namedValueFieldDefault({point: origin}), true);
    assert.equal(current.namedValueFieldDefault({point: staticOrigin}), false);
    assert.throws(() => current.namedValueFieldDefault({point: null}), TypeError);
    const originResource = current.originResourceDefault();
    assert.equal(current.originResourceDefault(undefined), originResource);
    assert.equal(current.originResourceDefault(originResource), originResource);
    assert.equal(current.NamedResource.origin, originResource);
    let originClosed;
    assert.equal(current.namedResourceUse(() => {
      originClosed = originResource.close();
      assert.equal(current.NamedResource.cleanups, 0);
    }), 33);
    await originClosed;
    assert.equal(current.NamedResource.cleanups, 1);
    assert.equal(originResource.close(), originClosed);
    assert.throws(() => current.originResourceDefault(), /closing|closed/i);
    await hiddenDefaults(current);
    await hiddenValueDefaults(current);
    await resourceDefaults(current, callback => { onSignalRead = callback; });
    await inaccessibleResourceDefaults(current, callback => { onSignalRead = callback; });
    assert.throws(() => current.identity({value: 4}), TypeError);
  }
  assert.throws(() => native.identity(wasm.singleton()), TypeError);
  assert.throws(() => wasm.identity(native.singleton()), TypeError);
  native.reset(); wasm.reset();
  native.add(1);
  assert.equal(wasm.calls(), 0);
}

async function hiddenDefaults(current) {
  const point = current.hiddenDefault();
  assert.equal(point.value, 41);
  assert.equal(point.typeName, 'String');
  const typedPoint = current.hiddenTypedDefault();
  assert.equal(typedPoint.value, 42);
  assert.equal(typedPoint.typeName, 'int');
  assert.equal(current.hiddenTypedDefault(undefined), typedPoint);
  assert.equal(current.hiddenTypedDefault(point), point);
  assert.equal(current.hiddenDefault(undefined), point);
  assert.equal(current.hiddenDefault(point), point);
  for (const options of [undefined, {}, {point: undefined}, {point}]) {
    assert.equal(current.hiddenNamedDefault(options), point);
  }
  assert.equal(current.hiddenNamedDefault({point: null}), null);
  assert.throws(() => current.hiddenDefault(null), TypeError);
  assert.throws(() => current.hiddenDefault({value: 41}), TypeError);
  assert.throws(() => current.hiddenNamedDefault({point: {value: 41}}), TypeError);
  assert.equal(current.hiddenDefaultAfter(), 44);
  assert.equal(current.hiddenDefaultAfter(undefined, point), 44);
  assert.equal(current.hiddenDefaultAfter(2, undefined), 43);
  assert.throws(() => current.hiddenDefaultAfter('bad'), TypeError);
  assert.equal(current.hiddenContainerDefaults(), true);
  assert.equal(current.hiddenContainerDefaults({points: undefined, mapping: undefined}), true);
  assert.equal(current.hiddenContainerDefaults({points: [point]}), false);
  assert.throws(() => current.hiddenContainerDefaults({points: [null]}), TypeError);
  assert.equal(await current.hiddenDefaultLater(undefined), point);
  const calls = current.calls();
  assert.equal(current.hiddenDefaultVoid(), undefined);
  assert.equal(current.calls(), calls + 41);
  assert.throws(() => current.hiddenDefaultVoid({point: null}), TypeError);
  assert.equal(current.calls(), calls + 41);

  const owner = new current.HiddenDefault();
  assert.equal(owner.point, point);
  assert.equal(new current.HiddenDefault(undefined).point, point);
  assert.equal(new current.HiddenDefault(point).point, point);
  assert.equal(current.HiddenDefault.named({point: undefined}).point, point);
  assert.equal(current.HiddenDefault.create(undefined), point);
  assert.deepEqual(await Array.fromAsync(current.HiddenDefault.sequence()), [point]);
  assert.throws(() => new current.HiddenDefault(null), TypeError);
  const concrete = new current.HiddenIntDefault(9);
  assert.equal(concrete.value, 9);
  assert.equal(concrete.point, point);
  assert.equal(current.HiddenIntDefault.named(8, undefined).point, point);

  const resource = new current.Resource(2);
  const cleanups = current.cleanups();
  let closing;
  assert.equal(current.hiddenResourceUse(resource, () => {
    closing = resource.close();
    assert.equal(current.cleanups(), cleanups);
  }), 43);
  await closing;
  assert.equal(current.cleanups(), cleanups + 1);
  const asyncResource = new current.Resource(3);
  const pending = current.hiddenResourceLater(asyncResource);
  const asyncClosing = asyncResource.close();
  assert.equal(current.cleanups(), cleanups + 1);
  assert.equal(await pending, 44);
  await asyncClosing;
  assert.equal(current.cleanups(), cleanups + 2);
}

async function hiddenValueDefaults(current) {
  const point = current.hiddenDefault();
  for (const value of [{}, {origin: undefined}, {origin: point}]) {
    assert.deepEqual(current.hiddenNamedValue(value), {origin: point, count: 3});
  }
  assert.deepEqual(current.hiddenNamedValue({origin: null, count: 4}), {origin: null, count: 4});
  assert.throws(() => current.hiddenNamedValue({origin: {value: 41}}), TypeError);
  assert.deepEqual(current.hiddenPositionalValue({}), {offset: 3, point});
  assert.deepEqual(current.hiddenPositionalValue({offset: undefined, point}), {offset: 3, point});
  assert.deepEqual(current.hiddenPositionalValue({offset: 4, point: undefined}), {offset: 4, point});
  assert.throws(() => current.hiddenPositionalValue({point: null}), TypeError);

  const resource = new current.Resource(3);
  const payload = {tag: 'opaque'};
  const input = {payload, resource};
  const output = current.hiddenFactoryValue(input);
  assert.notEqual(output, input);
  assert.equal(output.payload, payload);
  assert.equal(output.resource, resource);
  assert.equal(output.point, point);
  assert.equal(current.hiddenFactoryValue({payload: undefined, resource}).payload, undefined);
  assert.deepEqual(current.hiddenIntValue({payload: 7, resource}), {payload: 7, resource, point});
  assert.throws(() => current.hiddenIntValue({payload: '7', resource}), TypeError);
  const calls = current.calls();
  assert.throws(() => current.hiddenFactoryValue({payload, resource, point: null}), TypeError);
  assert.equal(current.calls(), calls);
  await resource.close();

  const failing = new current.Resource(-1);
  const cleanups = current.cleanups();
  assert.throws(() => current.hiddenFactoryValue({payload, resource: failing}), /hidden value constructor failed/);
  assert.equal(current.calls(), calls);
  await failing.close();
  assert.equal(current.cleanups(), cleanups + 1);
}

async function inaccessibleResourceDefaults(api, onSignalRead) {
  const box = api.hiddenResourceDefault();
  const resource = api.ConstResource.constant(61);
  assert.equal(box.resource, resource);
  assert.equal(api.hiddenResourceDefault(undefined), box);
  const supplied = new api.HiddenResourceBox(new api.ConstResource(70));
  assert.equal(api.hiddenResourceDefault(supplied), supplied);
  assert.throws(() => api.hiddenResourceDefault(null), TypeError);
  let closed;
  onSignalRead(() => {
    closed = resource.close();
    assert.equal(api.ConstResource.cleanups(61), 0);
  });
  try {
    assert.equal(api.hiddenResourceDefaultSignal(new AbortController().signal), 61);
  } finally { onSignalRead(undefined); }
  assert(closed instanceof Promise);
  await closed;
  assert.equal(api.ConstResource.cleanups(61), 1);
  assert.throws(() => api.hiddenResourceDefault(), /closing|closed/i);
  assert.equal(api.hiddenResourceDefault(supplied), supplied);

  assert.equal(await api.hiddenResourceDefaultLater(() => {}), 62);
  let futureClosed;
  await assert.rejects(api.hiddenResourceDefaultLater(() => {
    futureClosed = api.ConstResource.constant(62).close();
    assert.equal(api.ConstResource.cleanups(62), 0);
  }, {box: undefined, fail: true}), /hidden resource Future failed/);
  await futureClosed;
  assert.equal(api.ConstResource.cleanups(62), 1);

  assert.deepEqual(await Array.fromAsync(api.hiddenResourceDefaultSequence()), [63, 64]);
  const stream = api.hiddenResourceDefaultSequence({box: undefined, fail: true});
  const first = await stream.next();
  assert.equal(first.value, 63);
  assert.equal(first.done, false);
  await assert.rejects(stream.next(), /hidden resource Stream failed/);
  await api.ConstResource.constant(63).close();
  assert.equal(api.ConstResource.cleanups(63), 1);

  assert.equal(api.hiddenResourceValue({}), 65);
  const beforeFailure = api.calls();
  assert.throws(() => api.hiddenResourceValue({amount: -1}), /hidden resource constructor failed/);
  assert.equal(api.calls(), beforeFailure);
  await api.ConstResource.constant(64).close();
  assert.equal(api.ConstResource.cleanups(64), 1);
  await supplied.resource.close();
}

async function resourceDefaults(api, onSignalRead) {
  const canonical = api.ConstResource.constant(21);
  assert.equal(api.resourceDefault(), canonical);
  assert.equal(api.resourceDefault(undefined), canonical);
  assert.equal(api.resourceDefault(canonical), canonical);
  for (const options of [undefined, {}, {value: undefined}, {value: canonical}]) {
    assert.equal(api.namedResourceDefault(options), true);
  }
  assert.equal(api.namedResourceDefault({value: null}), false);
  assert.equal(api.DefaultBase.resource(undefined).original, true);
  assert.equal(new api.DefaultChild().checkResource(), true);
  const beforeInvalid = api.ConstResource.calls;
  assert.throws(() => api.resourceDefault(null), TypeError);
  assert.throws(() => api.resourceDefaultChecked(undefined, 'bad'), TypeError);
  assert.equal(api.ConstResource.calls, beforeInvalid);
  await api.ConstResource.constant(25).close();
  assert.equal(api.ConstResource.cleanups(25), 1, 'failed conversion releases its default lease');
  await canonical.close();
  assert.throws(() => api.resourceDefault(), /closing|closed/i);
  assert.throws(() => api.DefaultBase.resource(), /closing|closed/i);
  assert.throws(() => new api.DefaultChild().checkResource(), /closing|closed/i);
  const fresh = new api.ConstResource(50);
  assert.equal(api.resourceDefault(fresh), fresh);
  assert.equal(api.DefaultBase.resource(fresh).original, false);

  const futureResource = api.ConstResource.constant(22);
  let futureClosed;
  const pending = api.resourceDefaultLater(() => {
    futureClosed = futureResource.close();
    assert.equal(api.ConstResource.cleanups(22), 0, 'callback cannot clean up an accepted Future use');
  }, {value: undefined});
  assert.equal(api.ConstResource.cleanups(22), 0);
  await assert.rejects(api.resourceDefaultLater(() => {}), /closing|closed/i);
  assert.equal(await api.resourceDefaultLater(() => {}, {value: fresh}), 50);
  assert.equal(await pending, 22);
  await futureClosed;
  assert.equal(api.ConstResource.cleanups(22), 1);
  assert.equal(futureResource.close(), futureClosed);

  const streamResource = api.ConstResource.constant(23);
  const stream = api.resourceDefaultSequence({value: undefined});
  const first = await stream.next();
  assert.equal(first.value, 23);
  assert.equal(first.done, false);
  await streamResource.close();
  const last = await stream.next();
  assert.equal(last.value, undefined);
  assert.equal(last.done, true);
  await stream.return();
  assert.equal(api.ConstResource.cancellations, 1);
  assert.equal(api.ConstResource.cleanups(23), 1);
  assert.throws(() => api.resourceDefaultSequence(), /closing|closed/i);

  const signalResource = api.ConstResource.constant(24);
  const signal = new AbortController().signal;
  let signalClosed;
  onSignalRead(() => {
    signalClosed = signalResource.close();
    assert.equal(api.ConstResource.cleanups(24), 0, 'default lease precedes signal admission');
  });
  try { assert.equal(api.resourceDefaultSignal(signal, undefined), 24); }
  finally { onSignalRead(undefined); }
  assert(signalClosed instanceof Promise, 'captured signal intrinsic exercised reentrant cleanup');
  await signalClosed;
  assert.equal(api.ConstResource.cleanups(24), 1);
  assert.throws(() => api.resourceDefaultSignal(signal), /closing|closed/i);
  assert.equal(api.resourceContainerDefaults(), true);
  assert.equal(api.resourceContainerDefaults(undefined, undefined, undefined, undefined), true);
  for (const options of [undefined, {}, {values: undefined}]) {
    assert.equal(api.namedResourceContainerDefault(options), true);
  }
  assert.equal(api.namedResourceContainerDefault({values: null}), false);
  const beforeContainerErrors = api.ConstResource.calls;
  assert.throws(() => api.resourceContainerChecked(undefined, 'bad'), TypeError);
  assert.throws(() => api.resourceContainerDefaults(undefined,
    new Map([['both', [{}]]])), TypeError);
  assert.equal(api.ConstResource.calls, beforeContainerErrors);
  await api.ConstResource.constant(28).close();
  assert.equal(api.ConstResource.cleanups(28), 1);

  const containerResource = api.ConstResource.constant(26);
  let containerClosed;
  const containerPending = api.resourceContainerLater(() => {
    containerClosed = containerResource.close();
    assert.equal(api.ConstResource.cleanups(26), 0);
  }, {values: undefined});
  assert.throws(() => api.resourceContainerDefaults(), /closing|closed/i);
  await assert.rejects(api.resourceContainerLater(() => {}), /closing|closed/i);
  assert.equal(await api.resourceContainerLater(() => {}, {values: [fresh, fresh]}), 100);
  assert.equal(api.resourceContainerDefaults([fresh, fresh],
    new Map([['both', [fresh]]]), {both: [fresh]}, {$1: [fresh], resource: fresh}), false);
  assert.equal(await containerPending, 52);
  await containerClosed;
  assert.equal(api.ConstResource.cleanups(26), 1, 'duplicate default references release every lease');
  assert.throws(() => api.namedResourceContainerDefault(), /closing|closed/i);
  assert.equal(api.namedResourceContainerDefault({values: null}), false);

  const containerSignalResource = api.ConstResource.constant(27);
  let containerSignalClosed;
  onSignalRead(() => {
    containerSignalClosed = containerSignalResource.close();
    assert.equal(api.ConstResource.cleanups(27), 0);
  });
  try { assert.equal(api.resourceContainerSignal(new AbortController().signal), 27); }
  finally { onSignalRead(undefined); }
  assert(containerSignalClosed instanceof Promise);
  await containerSignalClosed;
  assert.equal(api.ConstResource.cleanups(27), 1);

  const containerStreamResource = api.ConstResource.constant(29);
  const containerStream = api.resourceContainerSequence({values: undefined});
  const containerFirst = await containerStream.next();
  assert.equal(containerFirst.value, 29);
  assert.equal(containerFirst.done, false);
  await containerStreamResource.close();
  const containerLast = await containerStream.next();
  assert.equal(containerLast.value, undefined);
  assert.equal(containerLast.done, true);
  await containerStream.return();
  assert.equal(api.ConstResource.cancellations, 2);
  assert.equal(api.ConstResource.cleanups(29), 1);
  assert.throws(() => api.resourceContainerSequence(), /closing|closed/i);
  await fresh.close();
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
