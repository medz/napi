import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
// This literal native import is the consumer API under test.
import { Counter, requiredOpaque, optionalOpaque, optionalNumber } from './module.wasm';
import { Counter as OtherCounter } from './second/module.wasm';
// Private-core diagnostics only verify business calls and instance isolation.
import * as core from './core.wasm';
import * as secondCore from './second/core.wasm';
import * as hostValues from './public_api.mjs';

let assertions = 0;
function equal(actual, expected) { assertions++; assert.strictEqual(actual, expected); }
function throws(fn, expected = TypeError) { assertions++; assert.throws(fn, expected); }

const publicModule = await WebAssembly.compile(await readFile(new URL('./module.wasm', import.meta.url)));
equal(JSON.stringify(WebAssembly.Module.exports(publicModule)), JSON.stringify([
  {name: 'Counter', kind: 'global'},
  {name: 'requiredOpaque', kind: 'global'},
  {name: 'optionalOpaque', kind: 'global'},
  {name: 'optionalNumber', kind: 'global'},
]));
for (const name of ['Counter', 'requiredOpaque', 'optionalOpaque', 'optionalNumber']) {
  const binding = {Counter, requiredOpaque, optionalOpaque, optionalNumber}[name];
  equal(binding, hostValues[name]);
  equal(typeof binding, 'function');
  equal(binding instanceof WebAssembly.Global, false);
}

// Native ESM repeats/concurrent imports reuse the same linked module and values.
const firstImport = await import('./module.wasm');
const repeatedImport = await import('./module.wasm');
equal(firstImport, repeatedImport);
const concurrentImports = await Promise.all([
  import('./module.wasm'),
  import('./module.wasm'),
  import('./module.wasm'),
]);
for (const imported of concurrentImports) equal(imported, firstImport);
for (const imported of [firstImport, repeatedImport, ...concurrentImports]) {
  equal(imported.Counter, Counter);
  equal(imported.requiredOpaque, requiredOpaque);
  equal(imported.optionalOpaque, optionalOpaque);
  equal(imported.optionalNumber, optionalNumber);
}

// Importing the package does not run application main or construct instances.
equal(core.constructorCount(), 0);
equal(secondCore.constructorCount(), 0);
const first = new Counter(2);
const second = new Counter(20);
equal(first === second, false);
equal(core.constructorCount(), 2);
equal(first instanceof Counter, true);
equal(first.value, 2);
equal(second.value, 20);
equal(first.add(3), 5);
equal(first.add(4), 9);
equal(second.add(-2), 18);
equal(first.value, 9);
equal(second.value, 18);
const defaulted = new Counter();
equal(defaulted.value, 0);
throws(() => Counter());
throws(() => new Counter('1'));
throws(() => first.add());
throws(() => first.add(1.5));
throws(() => first.add(2 ** 31));
throws(() => Counter.prototype.add.call({}, 1));
const detached = first.add;
throws(() => detached(1));
equal(detached.call(first, 1), 10);

const foreign = new OtherCounter(100);
equal(foreign.add(5), 105);
equal(secondCore.constructorCount(), 1);
equal(core.constructorCount(), 3);
equal(foreign instanceof Counter, false);
throws(() => Counter.prototype.add.call(foreign, 1));
throws(() => OtherCounter.prototype.add.call(first, 1));
throws(() => Object.getOwnPropertyDescriptor(Counter.prototype, 'value').get.call(foreign));
equal(first.value, 10);
equal(foreign.value, 105);

const overflow = new Counter(2147483647);
throws(() => overflow.add(1));
equal(overflow.value, 2147483647);
// A shadowed public getter cannot bypass the pre-mutation ABI range check.
Object.defineProperty(overflow, 'value', {value: 0});
throws(() => overflow.add(1));
equal(Object.getOwnPropertyDescriptor(Counter.prototype, 'value').get.call(overflow), 2147483647);
const underflow = new Counter(-2147483648);
throws(() => underflow.add(-1));
equal(underflow.value, -2147483648);

// Calls really cross into Dart; invalid required omission is caught pre-ABI.
const before = core.opaqueCount();
throws(() => requiredOpaque());
equal(core.opaqueCount(), before);
const values = [undefined, null, true, false, 0, -0, NaN, Infinity, '', 'value',
  10n, Symbol('opaque'), {}, [], () => 1, new Date(0)];
for (const value of values) {
  equal(requiredOpaque(value), value);
  equal(optionalOpaque(value), value);
}
equal(core.opaqueCount(), before + values.length * 2);
equal(optionalOpaque(), 'dart-default');
equal(optionalOpaque(undefined), undefined);
equal(optionalOpaque(null), null);
equal(requiredOpaque(undefined), undefined);
equal(requiredOpaque(null), null);
const opaque = { nested: { n: 1 } };
equal(requiredOpaque(opaque), opaque);
equal(optionalOpaque(opaque), opaque);

const beforeNumber = core.numberCount();
equal(optionalNumber(), 7);
equal(optionalNumber(undefined), 7);
equal(optionalNumber(0), 0);
equal(optionalNumber(-1), -1);
equal(optionalNumber(2147483647), 2147483647);
equal(optionalNumber(-2147483648), -2147483648);
equal(core.numberCount(), beforeNumber + 6);
for (const value of [null, true, '1', NaN, Infinity, 1.5, 2147483648, -2147483649, 1n, {}, []]) {
  throws(() => optionalNumber(value));
}
equal(core.numberCount(), beforeNumber + 6);

// The imported JS function preserves actual argument count even via apply.
throws(() => Reflect.apply(requiredOpaque, undefined, []));
equal(Reflect.apply(requiredOpaque, undefined, [undefined]), undefined);
equal(Reflect.apply(optionalOpaque, undefined, []), 'dart-default');
equal(Reflect.apply(optionalOpaque, undefined, [undefined]), undefined);
// Ordinary JavaScript calls ignore surplus arguments; presence uses actual argc.
equal(requiredOpaque(undefined, 'ignored'), undefined);
equal(optionalOpaque(undefined, 'ignored'), undefined);
equal(optionalOpaque('first', 'ignored'), 'first');
equal(optionalNumber(undefined, 99), 7);
equal(optionalNumber(5, 99), 5);
equal(new Counter(3, 'ignored').value, 3);
equal(first.add(0, 99), 10);
throws(() => Counter.prototype.add.call(Object.create(Counter.prototype), 1));
throws(() => Counter.prototype.add.call(new Proxy(first, {}), 1));

// Repeated state mutation stays in real retained Dart objects.
for (let i = 0; i < 100; i++) equal(first.add(1), 11 + i);
equal(second.value, 18);
equal(foreign.value, 105);
console.log(`PASS: ${assertions} assertions; native Node ${process.version}; real Dart class and presence semantics`);
