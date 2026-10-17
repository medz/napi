import * as api from '@napi/concrete-fixture';
import * as direct from '@napi/concrete-fixture/BACKEND';
import * as external from '@napi/concrete-external';
const integer = new api.IntCell(7);
const decimal = new api.DoubleCell(1.5);
const same: api.IntCell = api.equivalent(integer);
const named: api.IntCell = api.IntCell.named(9);
const adopted: api.IntCell = api.createInt(21);
const number: number = integer.value;
const self: api.IntCell = integer.self();
const nested: Map<string, number | null>[] = integer.nested();
const asyncNumber: Promise<number> = integer.futureValue();
const asyncCell: Promise<api.IntCell> = api.delayedInt(integer);
const stream: AsyncIterableIterator<number> = integer.values();
const list: (api.IntCell | null)[] = api.listCells([integer, null]);
const map: Map<api.IntCell, api.DoubleCell> = api.mapCells(new Map([[integer, decimal]]));
const pair: {first: api.IntCell, second: api.DoubleCell} = api.pair({first: integer, second: decimal});
const nullable = new api.NullableCell(null);
nullable.value = 2;
const batch = new api.BatchCell([new Map<string, number | null>([['a', 1], ['b', null]])]);
const leaf = new api.Leaf(1), leaves = new api.LeafCell(leaf);
const returnedLeaf: api.Leaf = leaves.value;
const directCell: api.IntCell = new direct.IntCell(1);
const selected: external.IntCell = new external.IntCell(1);
integer.optional(); integer.optional(null); integer.optional(undefined);
integer.namedOptional(); integer.namedOptional({next: null});
// @ts-expect-error Concrete aliases have no free logical type parameter.
new api.IntCell<string>('wrong');
// @ts-expect-error Concrete types have distinct nominal handle identities despite both mapping to number.
api.echoInt(decimal);
// @ts-expect-error Wrong concrete class cannot be assigned through identical structural fields.
const wrong: api.IntCell = decimal;
// @ts-expect-error Nullable specialization is a different runtime class identity.
api.echoInt(nullable);
// @ts-expect-error Required nullable value is not optional.
new api.NullableCell();
// @ts-expect-error Nullability does not add undefined to a required parameter.
new api.NullableCell(undefined);
// @ts-expect-error References keep concrete identity inside containers.
api.listCells([decimal]);
// @ts-expect-error References keep concrete identity in map keys and values.
api.mapCells(new Map([[decimal, integer]]));
// @ts-expect-error A leaf specialization contains Leaf, not arbitrary reference objects.
new api.LeafCell(integer);
// @ts-expect-error Closed nested substitutions remain typed.
new api.BatchCell([new Map([['bad', 'wrong']])]);
// @ts-expect-error Ordinary constructor retains scalar requirements.
new api.IntCell('7');
void [same, named, adopted, number, self, nested, asyncNumber, asyncCell, stream, list, map, pair, batch, returnedLeaf, directCell, selected, wrong];
