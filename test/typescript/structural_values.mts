import {
  structuralLists, structuralRecords, structuralNamed, structuralSingle,
  structuralEmpty, structuralBooleans, structuralDoubles, structuralStrings,
  structuralBigInts, structuralOptional, structuralNamedRequired,
  NamedList, namedListIdentity,
  structuralNamedOptional, structuralMixed,
} from './module.wasm';

const lists: Array<Array<number | null> | null> | null = structuralLists([[1, null], null]);
const records: Array<{$1: string; values: Array<number | null> | null;
  detail: {flag: boolean; ratio: number} | null} | null> = structuralRecords([
  {$1: 'x', values: [1], detail: {flag: true, ratio: 0}}, null,
]);
structuralNamed({values: null, nested: {label: 'x'}});
structuralNamed(null);
structuralSingle({$1: 1});
structuralEmpty({});
// @ts-expect-error empty records reject scalar values
structuralEmpty(1);
// @ts-expect-error empty records reject unknown fields
structuralEmpty({extra: 1});
structuralBooleans([true]);
structuralDoubles([0]);
structuralStrings(['x']);
structuralBigInts([{wide: 1n, huge: 1n << 300n}]);
structuralOptional();
structuralOptional(undefined);
structuralOptional(null);
structuralOptional([1, null]);
// @ts-expect-error nested leaves retain scalar number representation
structuralLists([[1n]]);
// @ts-expect-error required nullable list still requires an argument
structuralLists();
// @ts-expect-error required nullable list rejects undefined
structuralLists(undefined);
// @ts-expect-error record fields are required even when nullable
structuralRecords([{$1: 'x', values: null}]);
// @ts-expect-error unknown record fields are not declared
structuralSingle({$1: 1, unknown: 2});
// @ts-expect-error positional records are objects with $n fields
structuralSingle([1]);
// @ts-expect-error named record leaves remain strict
structuralNamed({values: null, nested: {label: 1}});
// @ts-expect-error double leaves do not coerce
structuralDoubles(['0']);
// @ts-expect-error bigint selection applies recursively to Dart ints
structuralBigInts([{wide: 1, huge: 1n}]);
// @ts-expect-error optional nullable list does not permit undefined elements
structuralOptional([undefined]);
void [lists, records];

const namedRequired: Array<number | null> | null = structuralNamedRequired({value: null});
const namedOptional: Array<number | null> | null = structuralNamedOptional({value: undefined});
const mixed: Array<number | null> | null = structuralMixed([1, null], undefined);
// @ts-expect-error required named container stays required
structuralNamedRequired({});
// @ts-expect-error required nullable is not undefined
structuralNamedRequired({value: undefined});
// @ts-expect-error required positional structure remains required
structuralMixed();
void [namedRequired, namedOptional, mixed];

const namedList: NamedList = namedListIdentity(new NamedList(1));
// @ts-expect-error a user class named List is not a structural array
namedListIdentity([]);
void namedList;
