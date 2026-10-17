import * as api from '@napi/futures-fixture';
import * as direct from '@napi/futures-fixture/BACKEND';
import type {FuturePoint} from '@napi/futures-fixture';
import {Promise as DartPromise} from '@napi/futures-fixture';

const value: Promise<number> = api.futureValue(1);
const empty: Promise<void> = api.futureVoid();
const nullable: Promise<string | null> = api.futureNullable(null);
const text: Promise<string> = api.futureText('text');
const wide: Promise<bigint> = api.futureWide(1n);
const huge: Promise<bigint> = api.futureBigInt(1n << 128n);
const numbers: Promise<number[]> = api.futureSnapshot([1], {offset: 2});
const defaults: Promise<number> = api.futureDefault(undefined);
const required: Promise<number> = api.futureRequired({value: null});
const counter = new api.FutureCounter(2);
const current: Promise<number> = counter.current;
const method: Promise<number> = counter.add();
const retained: Promise<number> = counter.hold();
const label: Promise<string> = api.FutureCounter.label();
const box = new api.FutureBox(3);
const identity: Promise<api.FutureBox> = api.futureReference(box);
const named: globalThis.Promise<DartPromise> = api.futureNamedPromise(new DartPromise(6));
const row: Promise<{$1: api.FutureBox; peers: (api.FutureBox | null)[]}> =
  api.futureRows({$1: box, peers: [box, null]});
const map: Promise<Map<string, api.FutureBox | null>> = api.futureMap(new Map([['box', box]]));
const dictionary: Promise<{[key: string]: api.FutureBox | null}> = api.futureDictionary({box, empty: null});
const nullableRows: Promise<(api.FutureBox | null)[] | null> = api.futureNullableRows([box, null]);
api.futureNullableRows(null);
const point: Promise<FuturePoint> = api.futurePoint({x: 1});
const subpath: Promise<number> = direct.futureValue(2);
// @ts-expect-error Future output is a Promise, not an eagerly returned payload.
const eager: number = api.futureValue(1);
// @ts-expect-error Future<void> remains void rather than an arbitrary payload.
const wrongVoid: Promise<number> = api.futureVoid();
// @ts-expect-error bigint input remains strict.
api.futureWide(1);
// @ts-expect-error required named presence is retained.
api.futureRequired({});
// @ts-expect-error required nullable input does not accept undefined.
api.futureNullable(undefined);
// @ts-expect-error future getters remain readonly.
counter.current = Promise.resolve(2);
// @ts-expect-error a Dictionary payload remains a plain object, not a Map.
api.futureDictionary(new Map());
// @ts-expect-error nullable containers do not admit undefined.
api.futureNullableRows(undefined);
void [value, empty, nullable, text, wide, huge, numbers, defaults, required,
  current, method, retained, label, identity, named, row, map, dictionary,
  nullableRows, point, subpath, eager, wrongVoid];
