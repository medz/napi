import {structuralLists, structuralRecords} from '@napi/foundation-fixture';
import {structuralLists as subpath} from '@napi/foundation-fixture/module.wasm';

const result: Array<Array<number | null> | null> | null = structuralLists([[1, null]]);
subpath(null);
structuralRecords([{$1: 'x', values: null, detail: null}]);
// @ts-expect-error strict scalar leaves survive package exports
structuralLists([['1']]);
// @ts-expect-error nullable record fields remain required
structuralRecords([{$1: 'x', values: null}]);
void result;
