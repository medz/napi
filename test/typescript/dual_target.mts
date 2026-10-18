import * as root from '@napi/dual-fixture';
import * as native from '@napi/dual-fixture/native';
import * as wasm from '@napi/dual-fixture/wasm';
import * as direct from '@napi/dual-fixture/module.wasm';
import * as nativeRoot from '@napi/dual-external';
import * as selectedNative from '@napi/dual-external/native';
import type {Row} from '@napi/dual-fixture';

const inputRow = {label: 'row', values: [1, 2]} as const;
const row: Row = root.appendRow(inputRow);
const nativeRow: native.Row = native.appendRow(inputRow);
const wasmRow: wasm.Row = wasm.appendRow(inputRow);
const externalRow: selectedNative.Row = nativeRoot.appendRow(inputRow);
for (const value of [row, nativeRow, wasmRow, externalRow]) value.values.push(4);
// @ts-expect-error Readonly inputs retain their element type.
root.appendRow({label: 'row', values: ['bad']} as const);
// @ts-expect-error The public record type retains required fields.
const missingRow: Row = {label: 'row'};
void missingRow;

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

const defaults: boolean = wasm.structuralDefaults(undefined, new Map([['a', [1, null]]]));
const namedDefault: boolean = native.namedDefaults({wide: undefined});
const defaultObject = new root.DefaultBase(undefined);
const defaultNamed: root.DefaultBase = root.DefaultBase.named({});
const inherited: Promise<boolean> = new root.DefaultChild().later();
void [defaults, namedDefault, defaultObject, defaultNamed, inherited];
// @ts-expect-error Non-null structural defaults do not make null a valid input.
wasm.structuralDefaults(null);
// @ts-expect-error Supplied lists still use their scalar contract.
native.namedDefaults({wide: [1n]});
