import cjs = require('@fixture/counter');
import type { Counter as EsmCounter } from '@fixture/counter' with { 'resolution-mode': 'import' };

const sameBrand: EsmCounter = new cjs.Counter(5);
declare const esmValue: EsmCounter;
const reverse: cjs.Counter = esmValue;
const value: number = sameBrand.increment();
declare const structural: { [K in keyof cjs.Counter]: cjs.Counter[K] };
// @ts-expect-error A structural copy has no native Counter identity.
const notCounter: cjs.Counter = structural;
// @ts-expect-error Omitted defaults do not accept explicit undefined.
new cjs.Counter(undefined);
