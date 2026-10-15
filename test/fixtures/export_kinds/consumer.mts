import { Counter, requiredOpaque, optionalOpaque, optionalNumber } from './module.wasm';

const counter: Counter = new Counter(2);
const result: number = counter.add(3);
const current: number = counter.value;
new Counter();
new Counter(undefined);
const undefinedValue: undefined = requiredOpaque(undefined);
const nullValue: null = requiredOpaque(null);
const identity = { nested: { value: 1 } };
const sameShape: typeof identity = requiredOpaque(identity);
const symbol: symbol = optionalOpaque(Symbol('opaque'));
const integer: bigint = optionalOpaque(3n);
const selectedDefault: 'dart-default' = optionalOpaque();
const suppliedUndefined: undefined = optionalOpaque(undefined);
const suppliedNull: null = optionalOpaque(null);
const defaultNumber: number = optionalNumber();
const undefinedNumber: number = optionalNumber(undefined);
const explicitNumber: number = optionalNumber(0);

// @ts-expect-error A required opaque argument may be undefined but not omitted.
requiredOpaque();
// @ts-expect-error An ordinary number parameter is not an arbitrary opaque value.
optionalNumber(null);
// @ts-expect-error Counter's constructor is typed.
new Counter('1');
// @ts-expect-error The exported class requires new.
Counter(1);
// @ts-expect-error A required delta cannot be omitted.
counter.add();
// @ts-expect-error Counter's method is typed.
counter.add('1');
// @ts-expect-error Only one declared argument is accepted by TypeScript.
requiredOpaque(1, 2);
// @ts-expect-error The retained state getter is read-only.
counter.value = 3;
// @ts-expect-error The private brand prevents structural Counter lookalikes.
const forged: Counter = { value: 1, add: () => 2 };
void [result, current, undefinedValue, nullValue, sameShape, symbol, integer,
  selectedDefault, suppliedUndefined, suppliedNull, defaultNumber,
  undefinedNumber, explicitNumber, forged];
