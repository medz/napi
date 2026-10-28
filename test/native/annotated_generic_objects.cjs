'use strict';

const assert = require('node:assert/strict');

module.exports = async function verifyAnnotatedGenericObjects(path) {
  const addon = require(path);
  const input = { value: 7 };
  const integer = addon.echoInt(input);
  assert.notEqual(integer, input);
  assert.deepEqual(integer, {
    value: 7, optional: null, note: 'kept', intType: true, stringType: false, isDoubleType: false,
  });
  assert.deepEqual(addon.echoText({ value: 'hello', optional: 'next', note: 'custom' }), {
    value: 'hello', optional: 'next', note: 'custom', intType: false, stringType: true, isDoubleType: false,
  });
  const double = addon.echoDouble({ value: 3 });
  assert.equal(double.value, 3);
  assert.equal(double.isDoubleType, true);
  integer.value = 9;
  assert.equal(input.value, 7);
  assert.equal(addon.nullable(), null);
  assert.equal(addon.nullable(null), null);
  assert.equal(addon.nullable({ value: 2 }).intType, true);
  const object = { token: 1 };
  assert.equal(addon.echo({ value: object }).value, object);
  assert.equal(addon.echo({ value: 3 }).value, 3);
  assert.deepEqual(addon.echoPoint({ value: { value: '3' }, optional: { value: '4' } }), {
    value: { value: 3 }, optional: { value: 4 }, note: 'kept', intType: false, stringType: false, isDoubleType: false,
  });
  const bounced = addon.bounce(value => {
    assert.equal(value.value.value, 3);
    return { value: { value: String(value.value.value + 1) } };
  });
  assert.equal(bounced({ value: { value: '3' } }).value.value, 4);
  assert.throws(() => addon.bounce(value => value)({ value: { value: '3' } }), TypeError);
  const grouped = await addon.groups(Promise.resolve({
    one: [{ value: { value: '5' } }, null],
  }));
  assert.equal(grouped.one[0].value.value, 5);
  assert.equal(grouped.one[1], null);
  await assert.rejects(addon.groups(Promise.resolve({
    one: [{ value: { value: 5 } }],
  })), TypeError);
  assert.deepEqual(addon.readout(), { value: 7 });
  assert.deepEqual(addon.nestedReadout(), { value: { value: 7 } });
  const intFactory = () => 7;
  assert.equal(addon.echoIntProducer({ create: intFactory }).create, intFactory);
  const pointFactory = () => ({ value: '9' });
  const pointProducer = addon.echoPointProducer({ create: pointFactory });
  assert.notEqual(pointProducer.create, pointFactory);
  assert.deepEqual(pointProducer.create(), { value: 9 });
  const numberRun = value => value + 1;
  const numberHandler = addon.echoIntHandler({ run: numberRun });
  assert.equal(numberHandler.run, numberRun);
  assert.equal(numberHandler.run(3), 4);
  const amountRun = value => {
    assert.equal(typeof value.value, 'number');
    return { value: String(value.value + 2) };
  };
  const handler = addon.echoAmountHandler({ run: amountRun });
  assert.notEqual(handler.run, amountRun);
  const amount = handler.run({ value: '3' });
  assert.deepEqual(amount, { value: 5 });
  assert.deepEqual(Object.getOwnPropertySymbols(amount), []);
  assert.deepEqual(Object.keys(handler), ['run']);
  assert.deepEqual(addon.nativeHandler().run({ value: '3' }), { value: 4 });
  assert.deepEqual(addon.nativeListHandler().run([{ value: '3' }]), [{ value: 3 }]);
  assert.deepEqual(addon.nativeMapHandler().run({ one: { value: '4' } }), { one: { value: 4 } });
  const functionHandler = addon.nativeFunctionHandler();
  const functionResult = functionHandler.run(amount => {
    assert.equal(typeof amount.value, 'number');
    return { value: String(amount.value + 1) };
  });
  assert.deepEqual(functionResult({ value: '5' }), { value: 6 });
  const swapFactory = addon.nativeSwapHandler().run(() => ({
    value: 1, next: { value: { value: '7' }, next: null },
  }));
  assert.deepEqual(swapFactory(), {
    value: 1, next: { value: { value: 7 }, next: null },
  });
  let nestedCalls = 0;
  addon.getNestedCallback()({
    run: original => {
      assert.deepEqual(original({ value: '3' }), { value: 4 });
      return amount => {
        assert.deepEqual(amount, { value: 7 });
        nestedCalls++;
        return { value: '9' };
      };
    },
  });
  assert.equal(nestedCalls, 1);
  const nestedCallback = addon.nativeNestedCallbackHandler().run(holder => {
    const transform = holder.run(amount => ({ value: String(amount.value + 2) }));
    assert.deepEqual(transform({ value: '5' }), { value: 6 });
  });
  nestedCallback({
    run: original => {
      assert.deepEqual(original({ value: '3' }), { value: 5 });
      return amount => ({ value: String(amount.value + 1) });
    },
  });
  assert.deepEqual(await addon.nativeFutureHandler().run(Promise.resolve({ value: '7' })), { value: 7 });
  const fnHolder = addon.echoFnHolder({ run: value => value });
  assert.equal(fnHolder.run('hello'), 'hello');
  assert.equal(addon.applyFnHolder(fnHolder, 7), 7);
  const asyncFnHolder = addon.echoAsyncFnHolder({ run: async value => value });
  assert.equal(await asyncFnHolder.run('hello'), 'hello');
  assert.equal(await asyncFnHolder.run(7), 7);
  assert.equal(await addon.applyAsyncFnHolder(asyncFnHolder, 7), 7);
  assert.equal(await addon.asyncScalarBound({ run: async value => value }), true);
  await assert.rejects(addon.asyncScalarBound({ run: async () => 'wrong' }), TypeError);
  const chain = { next: () => chain };
  const copiedChain = addon.echoChain(chain);
  assert.equal(typeof copiedChain.next().next().next, 'function');
  assert.equal(addon.nullableNextUsesSelf({ next: null }), true);
  assert.equal(addon.nullableNextUsesSelf({ next: { next: null } }), false);
  assert.deepEqual(addon.echoListNextChain({ next: [{ next: null }] }), {
    next: { next: null },
  });
  assert.throws(() => addon.echoListNextChain({ next: { next: null } }), TypeError);
  assert.deepEqual(addon.echoOpaqueNext({ next: 'anything' }), { next: null });
  assert.throws(() => addon.echoOpaqueNext({ next: null }), TypeError);
  assert.deepEqual(addon.echoReferenceNext({ next: {} }), { next: null });
  assert.throws(() => addon.echoReferenceNext({ next: 'wrong' }), TypeError);
  assert.equal(addon.distinctNextUsesSelf({ next: { next: { value: 7 } } }), true);
  assert.equal(addon.recordNextMatches({ next: { value: 7 } }, 7), true);
  assert.equal(addon.recordNextMatches({ next: { value: 7 } }, 8), false);
  assert.equal(addon.mapNextMatches({ next: { value: 7 } }, 7), true);
  assert.equal(addon.mapNextMatches({ next: { value: 7 } }, 8), false);
  assert.equal(addon.dateNextMatches({ next: new Date(7) }, 7), true);
  assert.equal(addon.dateNextMatches({ next: new Date(7) }, 8), false);
  async function* streamNextValues() { yield 7; }
  assert.equal(await addon.streamNextMatches({ next: streamNextValues() }, 7), true);
  assert.equal(await addon.streamNextMatches({ next: streamNextValues() }, 8), false);
  const rawStreamNext = addon.echoRawStreamNext({ next: {} });
  const rawStreamValues = [];
  for await (const value of rawStreamNext.next) rawStreamValues.push(value);
  assert.deepEqual(rawStreamValues, []);
  let functionNextCalls = 0;
  assert.equal(addon.functionNextUsesSelf({ next: () => { functionNextCalls++; } }), true);
  assert.equal(functionNextCalls, 1);
  assert.deepEqual(addon.echoOptionalMapChain({ next: {} }), { next: {} });
  assert.deepEqual(addon.echoOptionalMapChain({ next: { child: null } }), { next: {} });
  assert.deepEqual(addon.echoEmptyReferenceView({ value: { token: 7 } }), { value: {} });
  assert.deepEqual(addon.echoEmptyReferenceView({ value: null }), { value: null });
  assert.equal(addon.echoStringifierView({ value: {} }).value.toString(), 'ok');
  assert.deepEqual(addon.echoRecordValue({ value: { value: 7 } }), { value: { value: 7 } });
  assert.deepEqual(addon.echoClassValueView({ value: { value: 7 } }), { value: { value: 7 } });
  const amountValueHandler = addon.nativeAmountValueHandler();
  assert.deepEqual(amountValueHandler.run({ value: { value: 7 } }), { value: { value: 7 } });
  assert.throws(() => amountValueHandler.run({ value: { value: '7' } }), TypeError);
  const linkedInput = { next: { next: { next: null } } };
  const linkedOutput = addon.echoLinkedA(linkedInput);
  assert.deepEqual(linkedOutput, linkedInput);
  assert.notEqual(linkedOutput, linkedInput);
  assert.notEqual(linkedOutput.next, linkedInput.next);
  const functionLoop = addon.echoFunctionLoop({
    value: [1], next: { value: [() => 7], next: null },
  });
  assert.equal(functionLoop.value, 1);
  assert.equal(functionLoop.next.value(), 7);
  assert.equal(functionLoop.next.next, null);
  assert.deepEqual(addon.echoRecordLoop({
    value: [1], next: { value: [[2]], next: null },
  }), { value: 1, next: { value: [2], next: null } });
  const asyncChain = addon.echoAsyncChain({
    next: Promise.resolve({ next: Promise.resolve(null) }),
  });
  assert.equal(await (await asyncChain.next).next, null);
  const futureCallbackInput = { next: Promise.resolve(() => futureCallbackInput) };
  const futureCallbackChain = addon.echoFutureCallbackChain(futureCallbackInput);
  assert.equal(typeof (await (await futureCallbackChain.next)().next), 'function');
  const futureMapInput = { next: Promise.resolve({ one: () => futureMapInput }) };
  const futureMapChain = addon.echoFutureMapChain(futureMapInput);
  const futureMap = await futureMapChain.next;
  assert.deepEqual(Object.keys(futureMap), ['one']);
  assert.equal(typeof futureMap.one, 'function');
  assert.equal(typeof (await futureMap.one().next).one, 'function');
  assert.equal(await addon.resolverMap(true), 7);
  const ordinaryResolverMap = await addon.resolverMap(false);
  let resolvedMapValue;
  ordinaryResolverMap.one(value => { resolvedMapValue = value; });
  assert.equal(resolvedMapValue, 9);
  const scalarThenCallback = (resolve = undefined) => {
    if (typeof resolve === 'function') resolve('scalar-extra');
    return 3;
  };
  assert.equal(addon.echoIntProducer({ create: scalarThenCallback }).create, scalarThenCallback);
  assert.equal(await addon.scalarThenMap(scalarThenCallback), 'scalar-extra');
  const concreteCycle = addon.echoConcreteCycle({
    value: '7', next: { value: Promise.resolve(9), next: null },
  });
  assert.equal(concreteCycle.value, 7);
  assert.equal(await concreteCycle.next.value, 9);
  assert.equal(concreteCycle.next.next, null);
  assert.deepEqual(addon.echoStabilizing({
    a: 1, b: 'root', next: { a: 2, b: [3], next: { a: 4, b: [5], next: null } },
  }), {
    a: 1, b: 'root', next: { a: 2, b: [3], next: { a: 4, b: [5], next: null } },
  });
  assert.deepEqual(addon.echoAlternating({
    value: '7', output: 8, next: { value: 1, output: 2, next: null },
  }), { value: 8, output: 8, next: null });
  assert.equal(addon.scalarBound({ run: value => value }), true);
  assert.throws(() => addon.scalarBound({ run: () => 'wrong' }), TypeError);
  const scopedBoundRun = value => value;
  const scopedBoundHost = addon.echoScopedBoundHost({ box: { run: scopedBoundRun } });
  assert.equal(scopedBoundHost.box.run[0], scopedBoundRun);
  assert.equal(scopedBoundHost.box.run[0](7), 7);
  assert.equal(addon.invokeScopedBoundHost({ box: { run: value => value } }), true);
  assert.throws(() => addon.invokeScopedBoundHost({ box: { run: () => 'wrong' } }), TypeError);
  const scalarBoxHost = { box: { run: async value => value } };
  assert.equal(await addon.echoScalarHost(scalarBoxHost).box.run(7), 7);
  assert.equal(await addon.invokeScalarHost(scalarBoxHost), true);
  await assert.rejects(addon.invokeScalarHost({ box: { run: async () => 'wrong' } }), TypeError);
  const scopeLoopSource = { run: async value => value, next: () => scopeLoopSource };
  assert.equal(await addon.echoScopeLoop(scopeLoopSource).next().run(7), 7);
  assert.deepEqual(addon.nativeStringHandler().run({ value: '7' }), { value: '7' });
  assert.throws(() => addon.nativeStringHandler().run({ value: 7 }), TypeError);
  assert.equal(await addon.nativeThenableHandler().run(Promise.resolve({ value: '7' })), 7);
  const thenableRecordHolder = addon.echoThenableRecordHolder({
    future: Promise.resolve({ value: 7 }),
  });
  assert.deepEqual(await thenableRecordHolder.future, { value: 7 });
  const thenableChain = addon.echoThenableChain({
    then: resolve => resolve(7), next: Promise.resolve(null),
  });
  assert.equal(await thenableChain.next, null);
  assert.equal(await Promise.resolve(thenableChain), 7);
  const nullableThenChain = addon.echoNullableThenChain({
    then: null, next: Promise.resolve(null),
  });
  assert.equal(nullableThenChain.then, null);
  assert.equal(await nullableThenChain.next, null);
  const nullThenResult = await addon.asyncEchoNullableThenChain({
    then: null, next: Promise.resolve(null),
  });
  assert.equal(nullThenResult.then, null);
  assert.equal(await addon.asyncEchoNullableThenChain({
    then: resolve => resolve(7), next: Promise.resolve(null),
  }), 7);
  const finiteThenableHost = addon.echoFiniteThenableHost({
    future: Promise.resolve({ value: { value: 7 } }),
  });
  assert.equal(await finiteThenableHost.future, 7);
  assert.deepEqual(addon.applyAmount({ value: '4' }, {
    run: value => ({ value: String(value.value + 1) }),
  }), { value: 5 });
  const nestedHandler = addon.nestedHandler({ value: { run: amountRun } });
  assert.deepEqual(nestedHandler.value.run({ value: '6' }), { value: 8 });
  const erasedRun = value => value;
  const erased = addon.echoHandler({ run: erasedRun });
  const erasedValue = { value: '7' };
  assert.equal(erased.run, erasedRun);
  assert.equal(erased.run(erasedValue), erasedValue);
  assert.equal(addon.echo({ value: erasedValue }).value.value, '7');
  assert.throws(() => handler.run({ value: 3 }), TypeError);
  assert.throws(() => functionResult({ value: 5 }), TypeError);
  assert.throws(() => addon.echoAmountHandler({ run: value => value }).run({ value: '3' }), TypeError);
  assert.equal(addon.Envelope, undefined);
  assert.equal(addon.Readout, undefined);
  assert.equal(addon.Handler, undefined);
  assert.equal(addon.Amount, undefined);

  const recursive = { value: 1, next: { value: [2], next: { value: [[3]] } } };
  const copied = addon.echoRecursive(recursive);
  assert.deepEqual(copied, {
    value: 1, next: { value: [2], next: { value: [[3]], next: null } },
  });
  assert.notEqual(copied.next.value, recursive.next.value);
  assert.throws(() => addon.echoRecursive({ value: 1, next: { value: ['wrong'] } }), TypeError);
  for (const invalid of [
    { value: '7' }, {}, { value: 7, optional: undefined }, { value: 7, note: undefined },
  ]) {
    assert.throws(() => addon.echoInt(invalid), TypeError);
  }
  assert.throws(() => addon.echoInt({ value: 1.5 }), RangeError);
  assert.throws(() => addon.echoText({ value: 7 }), TypeError);
  assert.throws(() => addon.echoPoint({ value: { value: 3 } }), TypeError);
  assert.throws(() => addon.nullable(undefined), TypeError);
};
