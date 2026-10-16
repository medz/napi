import {Counter, Other, Scalars, Options, liveCounters} from '@napi/class-fixture';
import {Counter as Alias} from '@napi/class-fixture/module.wasm';
const counter: Counter = new Alias();
counter.value = counter.increment(undefined);
counter.named({amount: undefined});
counter.requiredNamed({amount: null});
const label: string = Counter.label();
const value: number = new Other().value;
const reset: void = counter.reset();
const count: number = liveCounters();
Counter.count = count;
const scalars = new Scalars();
scalars.integer = 1n;
scalars.nullable = null;
const empty: void = scalars.empty;
const tag: number = Scalars.constructor();
const option: string = new Options({amount: null}).label;
void [label, value, reset, option, empty, tag];
// @ts-expect-error scalar values are strict
counter.value = 'bad';
// @ts-expect-error readonly Dart field
new Other().value = 3;
// @ts-expect-error selected name replaces original name
counter.twice();
// @ts-expect-error ignored member is not exported
counter.hidden();
// @ts-expect-error required nullable remains required
counter.requiredNamed({amount: undefined});
// @ts-expect-error named constructor parameter is required
new Options();
// @ts-expect-error nullable field does not accept undefined
scalars.nullable = undefined;
// @ts-expect-error ordinary methods are not constructors
new counter.increment();

import {RefBox, Once, NamedReference, identityReference, nullableReference, optionalReference, namedReference} from '@napi/class-fixture';
const box: RefBox = RefBox.from(1);
const same: RefBox = identityReference(box);
const optional: RefBox | null = optionalReference(undefined);
const nullable: RefBox | null = nullableReference(null);
const named: RefBox | null = namedReference({value: box});
const factory: Once = new Once();
const container: NamedReference = NamedReference.make(box);
const shared: RefBox = RefBox.shared();
box.peer = same;
box.peer = null;
void [optional, nullable, named, factory, container, shared];
// @ts-expect-error private unnamed constructor
new NamedReference();
// @ts-expect-error references cannot be scalars
identityReference(1);
// @ts-expect-error required nullable remains required
nullableReference();
// @ts-expect-error required named reference rejects undefined
namedReference({value: undefined});
// @ts-expect-error selected constructor rename replaces Dart name
RefBox.named(1);
// @ts-expect-error property nullability does not imply undefined
box.peer = undefined;

import {RefCollection, echoReferenceRows, heldReferenceRows, holdReferenceRows, mixedReferenceRows} from '@napi/class-fixture';
const rows: Array<{$1: RefBox; peers: Array<RefBox | null> | null} | null> = echoReferenceRows([{$1: box, peers: [box, null]}, null]);
holdReferenceRows(rows);
holdReferenceRows(null);
const held: typeof rows | null = heldReferenceRows();
const refs: Array<RefBox | null> = mixedReferenceRows(box, [box, null]);
const collection = new RefCollection(refs, {counts: [1, null]});
collection.values = RefCollection.duplicate([box]);
collection.row = {$1: box, peers: [box, null]};
collection.row = null;
const copy: Array<RefBox | null> = collection.named({value: [box]});
const numbers: Array<number | null> | null = collection.optional(undefined);
const from: RefCollection = RefCollection.fromRows([box]);
void [held, copy, numbers, from];
// @ts-expect-error nested references reject scalar values
echoReferenceRows([{$1: box, peers: [1]}]);
// @ts-expect-error nullable container elements do not permit undefined
echoReferenceRows([undefined]);
// @ts-expect-error readonly structural field
collection.counts = [];
// @ts-expect-error required constructor structure
new RefCollection();
// @ts-expect-error required named structure
collection.named({value: undefined});
// @ts-expect-error renamed static member
RefCollection.echo([]);
