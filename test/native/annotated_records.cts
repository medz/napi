import addon = require('./addon');

const pair: [number, string] = addon.echoPair([1, 'text']);
const named: { text: string; value: bigint; maybe: number | null } =
  addon.echoNamed({ text: 'text', value: 1n, maybe: null });
const mixed: { $1: number; $2: number; length: number } =
  addon.echoMixed({ $1: 1, $2: 2, length: 3 });
const empty: [] = addon.echoEmpty([]);
const nullable: [number | null, string | null] | null = addon.nullablePair();
const nullableFields: [number | null, string | null] | null = addon.nullablePair([null, null]);
const defaultPair: [number, string] = addon.defaultPair();
const defaultNamed: { enabled: boolean; label: string } = addon.defaultNamed();
addon.defaultNamed({ value: { enabled: false, label: 'explicit' } });
const box = new addon.RecordBox(7);
const boxed: { item: addon.RecordBox; point: [number, number] } =
  addon.echoBoxed({ item: box, point: [1, 2] });
const holder = new addon.RecordHolder([1, 'value']);
holder.value = [2, 'next'];
const previous: [number, string] = holder.replace([3, 'last']);
const transformed: [number, number] = addon.transformPair([1, 2], ([a, b]) => [b, a]);
const swapped: [number, number] = addon.pairSwapper()([1, 2]);
const rows: { number: number; label: string | null }[] = addon.echoRows([{ number: 1, label: null }]);
const future: Promise<[number, string]> = addon.futurePair(Promise.resolve([1, 'future']));
const stream: AsyncIterableIterator<[number, string]> = addon.pairStream([1, 'stream']);
const collected: Promise<[number, string][]> = addon.collectPairs(stream);

// @ts-expect-error Tuple length is fixed.
addon.echoPair([1]);
// @ts-expect-error Tuple elements retain their types.
addon.echoPair(['1', 2]);
// @ts-expect-error Empty records accept only empty tuples.
addon.echoEmpty([1]);
// @ts-expect-error Nullable record fields remain required.
addon.echoNamed({ text: 'value', value: 1n });
// @ts-expect-error Nullable fields exclude undefined.
addon.echoNamed({ text: 'value', value: 1n, maybe: undefined });
// @ts-expect-error Mixed records use objects with their positional field names.
addon.echoMixed([1, 2, 3]);
// @ts-expect-error The legitimate named length field is required.
addon.echoMixed({ $1: 1, $2: 2 });
// @ts-expect-error Nullable records exclude undefined.
addon.nullablePair(undefined);
// @ts-expect-error Explicit default arguments exclude undefined.
addon.defaultPair(undefined);
// @ts-expect-error Explicit named default arguments exclude undefined.
addon.defaultNamed({ value: undefined });
// @ts-expect-error Callback results must retain the tuple shape.
addon.transformPair([1, 2], () => [1]);
// @ts-expect-error Class fields retain their record types.
holder.value = [1, 2];
