'use strict';

const assert = require('node:assert/strict');
const { join } = require('node:path');
const { pathToFileURL } = require('node:url');
const { Worker } = require('node:worker_threads');

module.exports = async function verifyAnnotatedGenerics(path, packageDirectory) {
  const addon = require(path);
  const object = { value: 7 };
  const array = [object];
  const callback = value => value;
  const symbol = Symbol('generic');
  for (const value of [42, 'hello', object, array, callback, symbol, null, undefined]) {
    assert.equal(addon.identity(value), value);
  }
  assert.equal(addon.nullable(null), null);
  assert.equal(addon.nullable(object), object);
  const paired = addon.pair(object, 'hello');
  assert.equal(paired[0], object);
  assert.equal(paired[1], 'hello');
  const box = new addon.Box(object);
  assert.equal(addon.box.value, 0);
  addon.box = box;
  assert.equal(addon.box, box);
  assert.equal(box.value, object);
  assert.equal(box.echo(object), object);
  assert.equal(addon.echoBox(box), box);
  assert.equal(box.items[0], object);
  assert.equal(box.named.value, object);
  const next = { value: 9 };
  assert.equal(box.replace(next), object);
  assert.equal(box.value, next);
  box.value = object;
  assert.equal(box.value, object);
  // Resolving a wide view first must not choose a different wrapper or codec.
  const integerBox = addon.wideBox();
  assert.equal(integerBox, addon.numericBox());
  assert.equal(integerBox, addon.intBox());
  assert(integerBox instanceof addon.Box);
  assert.equal(integerBox.holdsInt, true);
  assert.equal(integerBox.value, 7);
  assert.equal(integerBox.replace(8), 7);
  assert.deepEqual(integerBox.items, [8]);
  assert.deepEqual(integerBox.named, { value: 8 });
  assert.equal(addon.readBox(integerBox), 8);
  assert.equal(addon.echoBox(integerBox), integerBox);
  assert.equal(addon.consumeIntBox(integerBox), integerBox);
  assert.equal(addon.nullableIntBox(integerBox), integerBox);
  assert.equal(addon.nullableIntBox(null), null);
  for (const invalid of [1.5, 2 ** 53, '8', null, undefined]) {
    assert.throws(() => { integerBox.value = invalid; }, invalid === 1.5 || invalid === 2 ** 53 ? RangeError : TypeError);
    assert.equal(integerBox.value, 8);
  }
  assert.throws(() => addon.consumeIntBox(new addon.Box(8)), TypeError);
  assert.throws(() => addon.consumeIntBox(Object.create(addon.Box.prototype)), TypeError);
  assert.throws(() => addon.nullableIntBox(undefined), TypeError);
  assert.equal(addon.callIntBox(value => { assert.equal(value, integerBox); return value; }), integerBox);
  assert.equal(addon.intBoxIdentity()(integerBox), integerBox);
  assert.throws(() => addon.callIntBox(() => new addon.Box(8)), TypeError);
  assert.throws(() => addon.intBoxIdentity()(new addon.Box(8)), TypeError);
  const textBox = addon.textBox();
  assert.equal(textBox.value, null);
  assert.equal(textBox.replace('hello\u0000\ud800'), null);
  assert.equal(textBox.value, 'hello\u0000\ud800');
  assert.equal(addon.readBox(textBox), textBox.value);
  textBox.value = null;
  assert.throws(() => { textBox.value = undefined; }, TypeError);
  // Object? and dynamic are equivalent runtime views, not an ambiguity.
  const anyBox = addon.anyBox();
  assert.equal(anyBox.value, null);
  assert.equal(anyBox.replace(object), null);
  assert.equal(anyBox.value, object);
  assert.equal(addon.readBox(anyBox), object);
  anyBox.value = undefined;
  assert.equal(anyBox.value, undefined);
  assert.equal(anyBox.replace(42), undefined);
  assert.deepEqual(anyBox.items, [42]);
  const bigBox = addon.bigIntBox();
  assert.equal(bigBox.value, 1n << 100n);
  assert.equal(bigBox.replace(-(1n << 100n)), 1n << 100n);
  assert.throws(() => { bigBox.value = 1; }, TypeError);
  const referenceBox = addon.objectBox(object);
  assert.equal(referenceBox.value, object);
  assert.equal(addon.readBox(referenceBox), object);
  assert.equal(referenceBox.replace(callback), object);
  assert.equal(referenceBox.value, callback);
  assert.throws(() => { referenceBox.value = symbol; }, TypeError);
  const labeled = addon.parentBox();
  assert.equal(labeled, addon.labeledBox());
  assert(labeled instanceof addon.LabeledBox);
  assert(labeled instanceof addon.Box);
  assert.equal(labeled.label, 'labeled');
  assert.equal(labeled.holdsInt, true);
  assert.equal(labeled.replace(10), 9);
  assert.equal(addon.consumeIntBox(labeled), labeled);
  assert.throws(() => { labeled.value = 1.5; }, RangeError);
  assert.equal(addon.Box.prototype.replace.call(labeled, 11), 10);
  assert.equal(labeled.value, 11);
  const adjusted = addon.adjustedBox();
  assert.equal(adjusted.replace(5, 3), 3);
  assert.equal(adjusted.value, 8);
  assert.equal(adjusted.replace(5), 8);
  assert.equal(adjusted.value, 5);
  assert.equal(addon.Box.prototype.replace.call(adjusted, 9), 5);
  const scaled = addon.scaledBox();
  assert(scaled instanceof addon.ScaledBox);
  assert.equal(scaled.replace(4, true), 1);
  assert.equal(scaled.value, 8);
  assert.equal(scaled.replace(3), 8);
  assert.equal(scaled.value, 3);
  assert.equal(addon.Box.prototype.replace.call(scaled, 2), 3);
  const lists = addon.wideListBox();
  assert.equal(lists, addon.listBox());
  assert.equal(lists, addon.labeledListBox());
  assert(lists instanceof addon.LabeledBox);
  assert.equal(lists.label, 'labeled');
  const listOutput = lists.value;
  assert.deepEqual(listOutput, [1, 2]);
  listOutput.push(3);
  assert.deepEqual(lists.value, [1, 2]);
  const listInput = [3, 4];
  lists.value = listInput;
  listInput[0] = 99;
  assert.deepEqual(addon.readListBox(lists), [3, 4]);
  assert.equal(addon.consumeListBox(lists), lists);
  assert.deepEqual(lists.replace([5]), [3, 4]);
  assert.deepEqual(lists.items, [[5]]);
  assert.deepEqual(lists.named, { value: [5] });
  assert.deepEqual(addon.Box.prototype.replace.call(lists, [6]), [5]);
  for (const invalid of [null, undefined, [null], ['7'], [1, undefined]]) {
    assert.throws(() => { lists.value = invalid; }, TypeError);
  }
  for (const invalid of [[0.5], [2 ** 53]]) {
    assert.throws(() => { lists.value = invalid; }, RangeError);
  }
  assert.deepEqual(lists.value, [6]);
  const opaqueList = new addon.Box(listInput);
  assert.equal(opaqueList.value, listInput);
  assert.throws(() => addon.consumeListBox(opaqueList), TypeError);
  const maps = addon.mapBox();
  assert.deepEqual(maps.value, { items: [1, null] });
  const mapInput = { next: [2, null] };
  maps.value = mapInput;
  mapInput.next.push(3);
  assert.deepEqual(maps.value, { next: [2, null] });
  assert.throws(() => { maps.value = { next: [undefined] }; }, TypeError);
  const sets = addon.setBox();
  assert.deepEqual(sets.value, new Set([1, 2]));
  const setInput = new Set([3]);
  assert.deepEqual(sets.replace(setInput), new Set([1, 2]));
  setInput.add(4);
  assert.deepEqual(sets.value, new Set([3]));
  assert.throws(() => { sets.value = new Set([0.5]); }, RangeError);
  const records = addon.recordBox();
  assert(records instanceof addon.RecordBox);
  assert.deepEqual(records.value, { $1: 1, label: 'first' });
  assert.deepEqual(records.replace({ $1: 2, label: 'second' }), { $1: 1, label: 'first' });
  assert.throws(() => { records.value = { $1: 3 }; }, TypeError);
  assert.deepEqual(records.value, { $1: 2, label: 'second' });
  const pairs = addon.pairBox();
  assert(pairs instanceof addon.PairBox);
  assert.deepEqual(pairs.value, [1, 2]);
  assert.deepEqual(pairs.replace([3, 4]), [1, 2]);
  assert.deepEqual(addon.Box.prototype.replace.call(pairs, [5, 6]), [3, 4]);
  assert.throws(() => { pairs.value = [7, 'wrong']; }, TypeError);
  assert.deepEqual(pairs.value, [5, 6]);
  const nullableList = addon.nullableListBox();
  assert.equal(nullableList.value, null);
  nullableList.value = [7];
  assert.deepEqual(nullableList.replace(null), [7]);
  assert.throws(() => { nullableList.value = undefined; }, TypeError);
  const references = addon.referenceListBox([object, callback]);
  assert.equal(references.value[0], object);
  assert.equal(references.value[1], callback);
  assert.equal(references.replace([next])[0], object);
  assert.equal(references.value[0], next);
  assert.throws(() => { references.value = [symbol]; }, TypeError);
  const copied = addon.copyList(array);
  assert.notEqual(copied, array);
  assert.equal(copied[0], object);
  const map = { item: object };
  const copiedMap = addon.copyMap(map);
  assert.notEqual(copiedMap, map);
  assert.equal(copiedMap.item, object);
  assert.equal(addon.numeric(42), 42);
  assert.equal(addon.numeric(1.5), 1.5);
  assert.equal(addon.nullableNumeric(null), null);
  assert.equal(addon.nullableNumeric(7), 7);
  for (const value of ['7', null, undefined, object]) {
    assert.throws(() => addon.numeric(value), TypeError);
  }
  assert.throws(() => addon.nullableNumeric(undefined), TypeError);
  assert.equal(addon.nonNull(object), object);
  assert.equal(addon.nonNull(undefined), undefined);
  assert.throws(() => addon.nonNull(null), TypeError);
  assert.equal(addon.reference(object), object);
  assert.equal(addon.reference(callback), callback);
  assert.throws(() => addon.reference(symbol), TypeError);
  assert.equal(addon.apply(3, value => value + 1), 4);
  assert.equal(addon.apply(object, value => { assert.equal(value, object); return next; }), next);
  const child = new addon.NumericChild();
  assert.equal(child.echo(7), 7);
  assert.equal(child.echo(1.5), 1.5);
  assert.throws(() => child.echo('wrong'), TypeError);
  const genericChild = new addon.GenericNumericChild();
  assert.equal(genericChild.echo(1.5), 1.5);
  assert.throws(() => genericChild.echo('wrong'), TypeError);

  const counter = new addon.SpecialCounter(7);
  assert.equal(addon.boundIdentity(counter), counter);
  assert.equal(addon.nullableBound(counter), counter);
  assert.equal(addon.nullableBound(null), null);
  const counterBox = new addon.CounterBox(counter);
  assert.equal(counterBox.value, counter);
  assert.equal(counterBox.echo(counter), counter);
  const baseCounter = new addon.Counter(9);
  counterBox.value = baseCounter;
  assert.equal(counterBox.value, baseCounter);
  for (const invalid of [{ value: 7 }, Object.create(addon.Counter.prototype), box, null, undefined]) {
    assert.throws(() => addon.boundIdentity(invalid), TypeError);
    assert.throws(() => { counterBox.value = invalid; }, TypeError);
    assert.equal(counterBox.value, baseCounter);
  }
  let calls = 0;
  const boundCallback = value => {
    calls++;
    assert.equal(value, counter);
    assert.equal(value.label, 'special');
    value.value++;
    return value;
  };
  assert.equal(addon.boundCallback(counter, boundCallback), true);
  assert.equal(calls, 1);
  assert.equal(counter.value, 8);
  assert.equal(addon.boundFunction()(counter), counter);
  assert.equal(addon.returnBoundCallback(boundCallback), boundCallback);
  // A callback invoked as <SpecialCounter> must reject even a genuine base instance.
  assert.throws(() => addon.boundCallback(counter, () => baseCounter), TypeError);
  assert.throws(() => addon.boundCallback(counter, () => ({ value: 7 })), TypeError);
  assert.equal(addon.nullableBoundCallback(value => value), true);
  assert.throws(() => addon.nullableBoundCallback(() => undefined), TypeError);
  assert.equal(addon.handleCounter({ run: boundCallback }, counter), true);
  assert.throws(() => addon.handleCounter({ run: () => baseCounter }, counter), TypeError);
  assert.equal(addon.handleNullableCounter({ run: value => value }, counter), true);
  assert.equal(addon.handleNullableCounter({ run: value => value }, null), true);
  assert.equal(addon.counterHandler().run(counter), counter);
  assert.throws(() => addon.counterHandler().run({ value: 7 }), TypeError);
  assert.equal(await addon.asyncBoundCallback(counter, async value => {
    await new Promise(resolve => setImmediate(resolve));
    assert.equal(value.label, 'special');
    return value;
  }), counter);
  await assert.rejects(addon.asyncBoundCallback(counter, async () => baseCounter), TypeError);

  addon.registerObject();
  const objectHandler = addon.objectHandler();
  assert.equal(objectHandler.run(object), object);
  assert.equal(objectHandler.run('opaque'), 'opaque');

  await new Promise((resolve, reject) => {
    let completed = false;
    const child = new Worker(`
      const assert = require('node:assert/strict');
      const { parentPort, workerData } = require('node:worker_threads');
      const addon = require(workerData);
      const box = addon.wideBox();
      assert.equal(box, addon.intBox());
      assert.equal(box.replace(12), 7);
      assert.throws(() => { box.value = 0.5; }, RangeError);
      assert.equal(addon.callIntBox(value => value), box);
      const lists = addon.listBox();
      assert.deepEqual(lists.replace([3]), [1, 2]);
      assert.equal(lists, addon.labeledListBox());
      const value = new addon.SpecialCounter(7);
      assert.equal(addon.boundCallback(value, item => item), true);
      addon.asyncBoundCallback(value, async item => {
        await new Promise(resolve => setImmediate(resolve));
        return item;
      }).then(result => {
        assert.equal(result, value);
        parentPort.postMessage(true);
      });
    `, { eval: true, workerData: path });
    const timeout = setTimeout(() => {
      child.terminate();
      reject(new Error('Bound generic callback worker did not exit'));
    }, 10000);
    child.on('message', value => { completed = value === true; });
    child.on('error', reject);
    child.on('exit', code => {
      clearTimeout(timeout);
      if (code === 0 && completed) resolve();
      else reject(new Error(`Bound generic callback worker exited with ${code}`));
    });
  });
  if (packageDirectory) {
    const common = require(join(packageDirectory, 'index.cjs'));
    const module = await import(pathToFileURL(join(packageDirectory, 'index.mjs')).href);
    assert.equal(module.default, common);
    assert.equal(module.Box, common.Box);
    assert.equal(Object.hasOwn(module, 'box'), false);
    const value = new module.Box(7);
    module.default.box = value;
    assert.equal(common.box, value);
    assert.equal(module.echoBox(value), value);
    const concrete = module.intBox();
    assert.equal(concrete, common.wideBox());
    assert.equal(module.consumeIntBox(concrete), concrete);
    assert.throws(() => module.consumeIntBox(value), TypeError);
    assert.equal(module.listBox(), common.wideListBox());
    assert.deepEqual(module.readListBox(module.listBox()), [1, 2]);
  }
};
