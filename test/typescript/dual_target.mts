import * as root from '@napi/dual-fixture';
import * as native from '@napi/dual-fixture/native';
import * as wasm from '@napi/dual-fixture/wasm';
import * as direct from '@napi/dual-fixture/module.wasm';
import * as nativeRoot from '@napi/dual-external';
import * as selectedNative from '@napi/dual-external/native';

const a: wasm.Counter = new root.Counter();
const b: direct.Counter = a;
root.identity(b);
const c: selectedNative.Counter = new nativeRoot.Counter();
nativeRoot.identity(c);
const n: number = native.add(1);
const future: Promise<number> = wasm.later(n);
const stream: AsyncIterableIterator<number, undefined, undefined> = root.sequence(n);
const closed: Promise<void> = new native.Resource(1).close();
const v: void = native.reset();
void [future, stream, closed, v];
// @ts-expect-error Runtime owners differ even though their API text is identical.
native.identity(a);
// @ts-expect-error Resource owners also differ.
const resource: native.Resource = new wasm.Resource(1);
// @ts-expect-error Required argument.
wasm.add();
// @ts-expect-error Wrong scalar.
native.add('1');
// @ts-expect-error Unknown named option.
root.format('x', {unknown: true});
// @ts-expect-error Instances require genuine reference brands.
wasm.identity({value: 1, increment: () => 1});
