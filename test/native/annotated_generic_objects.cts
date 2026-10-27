import addon = require('./addon');

const integer: addon.Envelope<number> = addon.echoInt({ value: 7 });
const text: addon.Envelope<string> = addon.echoText({ value: 'hello', optional: 'next' });
const double: addon.Envelope<number> = addon.echoDouble({ value: 3 });
const inferred: addon.Envelope<number> = addon.echo({ value: 3 });
const explicit: addon.Envelope<string> = addon.echo<string>({ value: 'hello' });
const nullable: addon.Envelope<number> | null = addon.nullable();
const point: addon.Envelope<addon.Point> = addon.echoPoint({ value: { value: '3' } });
const pointValue: number = point.value.value;
const bounced = addon.bounce(value => ({ value: { value: String(value.value.value + 1) } }));
const bouncedValue: addon.Envelope<addon.Point> = bounced({ value: { value: '3' } });
const groups: Promise<Record<string, (addon.Envelope<addon.Point> | null)[]>> =
  addon.groups(Promise.resolve({ one: [{ value: { value: '5' } }, null] }));
const readout: addon.Readout<number> = addon.readout();
const nestedReadout: addon.Readout<addon.Readout<number>> = addon.nestedReadout();
const intProducer: addon.Producer<number> = addon.echoIntProducer({ create: () => 7 });
const pointProducer: addon.Producer<addon.Point> = addon.echoPointProducer({
  create: () => ({ value: '9' }),
});
const produced: number = pointProducer.create().value;
const handwrittenHandler: addon.Handler<number> = { run: value => value + 1 };
const numberHandler: addon.Handler<number> = addon.echoIntHandler(handwrittenHandler);
const handledNumber: number = numberHandler.run(3);
const handler: addon.Handler<addon.Amount> = addon.echoAmountHandler({
  run: amount => ({ value: String(amount.value + 2) }),
});
const amount: addon.Amount = handler.run({ value: '3' });
const amountValue: number = amount.value;
const nativeHandler: addon.Handler<addon.Amount> = addon.nativeHandler();
const nativeAmount: addon.Amount = nativeHandler.run({ value: '3' });
const listHandler: addon.Handler<addon.Amount[]> = addon.nativeListHandler();
const listedAmounts: addon.Amount[] = listHandler.run([{ value: '3' }]);
const mapHandler: addon.Handler<Record<string, addon.Amount>> = addon.nativeMapHandler();
const mappedAmounts: Record<string, addon.Amount> = mapHandler.run({ one: { value: '4' } });
const functionHandler = addon.nativeFunctionHandler();
const functionResult = functionHandler.run(amount => {
  const amountValue: number = amount.value;
  return { value: String(amountValue + 1) };
});
const functionAmount: addon.Amount = functionResult({ value: '5' });
const swapHandler = addon.nativeSwapHandler();
const swapFactory: () => addon.Swap<number, addon.Amount> = swapHandler.run(() => ({
  value: 1, next: { value: { value: '7' }, next: null },
}));
const swappedAmount: number | undefined = swapFactory().next?.value.value;
// @ts-expect-error Swapping type arguments retains Amount's String constructor input.
swapHandler.run(() => ({ value: 1, next: { value: { value: 7 }, next: null } }));
const nestedCallbackHandler: addon.Handler<ReturnType<typeof addon.getNestedCallback>> =
  addon.nativeNestedCallbackHandler();
const nestedCallback = nestedCallbackHandler.run(holder => {
  const transform = holder.run(amount => ({ value: String(amount.value + 2) }));
  const result: addon.Amount = transform({ value: '5' });
});
nestedCallback({ run: original => amount => ({ value: String(amount.value + 1) }) });
const futureHandler: addon.Handler<Promise<addon.Amount>> = addon.nativeFutureHandler();
const futureAmount: Promise<addon.Amount> = futureHandler.run(Promise.resolve({ value: '7' }));
const fnHolder: addon.FnHolder = { run: value => value };
const echoedFnHolder: addon.FnHolder = addon.echoFnHolder(fnHolder);
const genericNumber: number = echoedFnHolder.run(7);
const genericString: string = echoedFnHolder.run('hello');
const appliedGenericNumber: number = addon.applyFnHolder(fnHolder, 7);
const echoedAsyncFnHolder: addon.AsyncFnHolder = addon.echoAsyncFnHolder({
  run: async value => value,
});
const asyncGenericNumber: Promise<number> = echoedAsyncFnHolder.run(7);
const asyncGenericString: Promise<string> = echoedAsyncFnHolder.run('hello');
const appliedAsyncGenericNumber: Promise<number> = addon.applyAsyncFnHolder({
  run: async value => value,
}, 7);
const asyncBoundHolder: addon.AsyncBoundFnHolder = { run: async value => value };
const asyncScalarBound: Promise<boolean> = addon.asyncScalarBound(asyncBoundHolder);
const chain: addon.Chain = { next: () => chain };
const chained: addon.Chain = addon.echoChain(chain).next().next();
declare const nullableNext: addon.NullableNext;
const nonnullableNext: addon.NullableNext = nullableNext.next;
const nextUsesSelf: boolean = addon.nullableNextUsesSelf({ next: null });
const listNextChain: addon.ListNextChain = addon.echoListNextChain({
  next: [{ next: null }],
});
const listNextChild: addon.ListNextChain | null = listNextChain.next;
// @ts-expect-error The constructor takes an array, not the getter's object shape.
addon.echoListNextChain({ next: { next: null } });
const opaqueNext: addon.OpaqueNext = addon.echoOpaqueNext({ next: 'anything' });
const opaqueChild: addon.OpaqueNext | null = opaqueNext.next;
// @ts-expect-error The constructor's Object parameter is non-nullable.
addon.echoOpaqueNext({ next: null });
// @ts-expect-error The broad constructor input differs from the getter's data type.
const forgedOpaqueNext: addon.OpaqueNext = { next: null };
const referenceNext: addon.ReferenceNext = addon.echoReferenceNext({ next: {} });
const referenceChild: addon.ReferenceNext | null = referenceNext.next;
// @ts-expect-error A raw object reference is broader than this data type.
const forgedReferenceNext: addon.ReferenceNext = { next: null };
// @ts-expect-error JsObject references do not accept primitive strings.
addon.echoReferenceNext({ next: 'wrong' });
declare const distinctNext: addon.DistinctNext;
const distinctChild: addon.DistinctNext = distinctNext.next;
const distinctUsesSelf: boolean = addon.distinctNextUsesSelf({ next: { next: 7 } });
// @ts-expect-error These distinct constructor and getter shapes need output identity.
const forgedDistinctNext: addon.DistinctNext = { next: distinctNext };
const emptyReferenceView: addon.EmptyReferenceView = { value: {} };
const echoedEmptyReferenceView: addon.EmptyReferenceView =
  addon.echoEmptyReferenceView(emptyReferenceView);
const recordValue: addon.RecordValue = { value: { value: 7 } };
const echoedRecordValue: addon.RecordValue = addon.echoRecordValue(recordValue);
const classValueView: addon.ClassValueView = { value: { value: 7 } };
const echoedClassValueView: addon.ClassValueView = addon.echoClassValueView(classValueView);
const functionLoop: addon.FunctionLoop<number> = addon.echoFunctionLoop({
  value: [1], next: { value: [() => 7], next: null },
});
const loopFunction: (() => number) | undefined = functionLoop.next?.value;
const recordLoop: addon.RecordLoop<number> = addon.echoRecordLoop({
  value: [1], next: { value: [[2]], next: null },
});
const loopTuple: [number] | undefined = recordLoop.next?.value;
const asyncChain: addon.AsyncChain = addon.echoAsyncChain({
  next: Promise.resolve({ next: Promise.resolve(null) }),
});
const asyncNext: Promise<addon.AsyncChain | null> = asyncChain.next;
const futureCallbackChain: addon.FutureCallbackChain = addon.echoFutureCallbackChain({
  next: Promise.resolve(() => futureCallbackChain),
});
const futureCallback: Promise<() => addon.FutureCallbackChain> = futureCallbackChain.next;
const concreteCycle: addon.ConcreteCycleA = addon.echoConcreteCycle({
  value: '7', next: { value: Promise.resolve(9), next: null },
});
const concreteCycleValue: Promise<number> | undefined = concreteCycle.next?.value;
const stabilizing: addon.Stabilizing<number, string> = addon.echoStabilizing({
  a: 1, b: 'root', next: { a: 2, b: [3], next: { a: 4, b: [5], next: null } },
});
const stabilizedValue: number[] | undefined = stabilizing.next?.next?.b;
const alternating: addon.Alternating<number, string> = addon.echoAlternating({
  value: '7', output: 8, next: { value: 1, output: 2, next: null },
});
const alternatingValue: string[] | undefined = alternating.next?.value;
const scalarBound: boolean = addon.scalarBound({ run: value => value });
const scopedBoundHost: addon.ScopedBoundHost = addon.echoScopedBoundHost({
  box: { run: value => value },
});
const scopedBoundNumber: number = scopedBoundHost.box.run[0](7);
// @ts-expect-error The callback's closed numeric bound rejects strings.
scopedBoundHost.box.run[0]('wrong');
const scopedBoundNative: boolean = addon.invokeScopedBoundHost({
  box: { run: value => value },
});
const scalarBoxHost: addon.ScalarHost = { box: { run: async value => value } };
const echoedScalarBoxHost: addon.ScalarHost = addon.echoScalarHost(scalarBoxHost);
const scalarAsyncNumber: Promise<number> = echoedScalarBoxHost.box.run(7);
const scalarAsyncNative: Promise<boolean> = addon.invokeScalarHost(scalarBoxHost);
interface ScopeLoopSource {
  run<T>(value: T): Promise<T>;
  next<U>(): ScopeLoopSource;
}
const scopeLoopSource: ScopeLoopSource = {
  run: async value => value, next: () => scopeLoopSource,
};
const scopeLoop: addon.ScopeLoop = addon.echoScopeLoop(scopeLoopSource);
const scopeLoopResult: Promise<number> = scopeLoop.next().run(7);
const stringHandler = addon.nativeStringHandler();
const stringValue = stringHandler.run({ value: '7' });
const thenableHandler = addon.nativeThenableHandler();
const settledThenable: Promise<number> = thenableHandler.run(Promise.resolve({ value: '7' }));
const thenableRecordHolder: addon.ThenableRecordHolder = {
  future: Promise.resolve({ value: 7 }),
};
const thenableRecordOutput: addon.ThenableRecordHolder =
  addon.echoThenableRecordHolder(thenableRecordHolder);
const settledRecord: Promise<{ value: number }> = thenableRecordOutput.future;
const thenableChain: addon.ThenableChain = addon.echoThenableChain({
  then: resolve => resolve(7), next: Promise.resolve(null),
});
const thenableNext: Promise<number | null> = thenableChain.next;
const nullableThenChain: addon.NullableThenChain = addon.echoNullableThenChain({
  then: null, next: Promise.resolve(null),
});
const nullableThenNext: Promise<number | addon.NullableThenChain | null> = nullableThenChain.next;
const nullableThenFuture = addon.asyncEchoNullableThenChain({
  then: null, next: Promise.resolve(null),
});
const nullableThenResult: Promise<number | addon.NullableThenChain> = nullableThenFuture;
// @ts-expect-error A callable then may resolve a number.
const nullableThenObjectOnly: Promise<addon.NullableThenChain> = nullableThenFuture;
// @ts-expect-error A null then preserves the object.
const nullableThenNumberOnly: Promise<number> = nullableThenFuture;
const finiteThenableHost: addon.FiniteThenableHost = addon.echoFiniteThenableHost({
  future: Promise.resolve({ value: { value: 7 } }),
});
const finiteThenableValue: Promise<number> = finiteThenableHost.future;
interface Wrapped<T> { handler: addon.Handler<T>; }
const wrapped: Wrapped<addon.Amount> = { handler };
// @ts-expect-error Erasing Amount identity would change the handler's constructor input.
const erasedWrapped: Wrapped<{ value: number }> = wrapped;
const appliedAmount: addon.Amount = addon.applyAmount({ value: '4' }, {
  run: amount => ({ value: String(amount.value + 1) }),
});
const nestedHandler: addon.Envelope<addon.Handler<addon.Amount>> = addon.nestedHandler({
  value: { run: amount => ({ value: String(amount.value + 2) }) },
});
const nestedAmount: addon.Amount = nestedHandler.value.run({ value: '6' });
const erasedHandler = addon.echoHandler<addon.Amount>({ run: amount => amount });
const erasedAmount: addon.Amount = erasedHandler.run(amount);
const erasedEnvelope = addon.echo<addon.Amount>({ value: amount });
const erasedEnvelopeAmount: addon.Amount = erasedEnvelope.value;
const recursive: addon.Recursive<number> = addon.echoRecursive({
  value: 1, next: { value: [2], next: { value: [[3]] } },
});
const nested: number[][] | undefined = recursive.next?.next?.value;

// @ts-expect-error Closed generic constructors retain their concrete input type.
addon.echoInt({ value: '7' });
// @ts-expect-error Generic arguments preserve value relationships.
addon.echo<string>({ value: 3 });
// @ts-expect-error Nullable optional values do not accept explicit undefined.
addon.echoInt({ value: 7, optional: undefined });
// @ts-expect-error The nested constructor consumes String, not the output integer.
addon.echoPoint({ value: { value: 3 } });
// @ts-expect-error Output records do not satisfy the asymmetric input shape.
addon.echoPoint(point);
// @ts-expect-error Callback results use the nested input constructor shape.
addon.bounce(value => value);
// @ts-expect-error A returned adapter still requires the nested input shape.
bounced({ value: { value: 3 } });
// @ts-expect-error Recursive generic arguments transform at each level.
addon.echoRecursive({ value: 1, next: { value: ['wrong'] } });
// @ts-expect-error Data classes are type-only exports.
new addon.Envelope(3);
// @ts-expect-error Producer callbacks return the nested constructor's String input.
addon.echoPointProducer({ create: () => ({ value: 9 }) });
// @ts-expect-error Handler arguments use the Amount constructor's String shape.
handler.run({ value: 3 });
// @ts-expect-error Handler callbacks return input shapes, not Amount outputs.
addon.echoAmountHandler({ run: amount => amount });
// @ts-expect-error Asymmetric output identity cannot be forged by a plain literal.
const forgedAmount: addon.Amount = { value: 3 };
// @ts-expect-error Erased generic calls forward T as declared instead of using Amount's constructor input.
erasedHandler.run({ value: '7' });
// @ts-expect-error Recursive array inputs use the Amount constructor shape.
listHandler.run([{ value: 3 }]);
// @ts-expect-error Whole-function inputs return constructor input, not output values.
functionHandler.run(amount => ({ value: amount.value }));
// @ts-expect-error The resulting function also consumes String constructor input.
functionResult({ value: 5 });
// @ts-expect-error Dynamic output does not erase the constructor's String input.
stringHandler.run({ value: 7 });
// @ts-expect-error The awaited output is not the promised constructor input.
thenableHandler.run(Promise.resolve(7));
