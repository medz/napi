import {
  RefBox, ValuePoint, ValueRight, ValueSnapshot, echoValuePoint, nullableValuePoint, normalizeValue, echoValueNode,
  bigintValueNode, echoValueBranch, echoValueLeft, valueInterfaces, valueSnapshot,
  echoValueEnvelope, valueKeyMap, valueRows,
} from '@napi/class-fixture';
import type {
  ValueNormalized, ValueNode, ValueBranch, ValueLeft, ValueEnvelope,
} from '@napi/class-fixture';
import {echoValuePoint as direct} from '@napi/class-fixture/module.wasm';

const point: ValuePoint = echoValuePoint({x: 1});
const y: number = point.y;
const tag: number | null = point.tag;
echoValuePoint({x: 2, y: undefined, tag: undefined});
echoValuePoint({x: 3, tag: null});
direct({x: 4});
const nullable: ValuePoint | null = nullableValuePoint(null);
const normalized: ValueNormalized = normalizeValue({total: '12'});
const total: number = normalized.total;
const doubled: number = normalized.doubled;
const node: ValueNode = echoValueNode({value: 1, next: {value: 2}});
const branch: ValueBranch = echoValueBranch({label: 1, link: {text: 'next', branch: {label: 2}}});
const wide = bigintValueNode({value: 1n, next: {value: 2n, next: null}});
const wideValue: bigint = wide.value;
const wideNext: bigint | undefined = wide.next?.value;
const left: ValueLeft = echoValueLeft({left: 1});
const pair: {$1: ValueLeft; $2: ValueRight} = valueInterfaces(2);
const snapshot: ValueSnapshot = valueSnapshot();
const box = new RefBox(1);
const envelope: ValueEnvelope = echoValueEnvelope({
  points: [{x: 1}, null], nodes: new Map([['one', {value: 1}]]),
  names: {one: {x: 2}}, row: {$1: {x: 3}, owner: box}, owner: box,
});
const nestedRequired: number = envelope.points[0]!.y;
valueKeyMap(new Map([[{id: 1}, 2]]));
valueRows([{$1: {x: 1}, $2: 2}]);

// @ts-expect-error values are type-only exports, not JS constructors.
new ValuePoint(1);
// @ts-expect-error output fields are required even when input has defaults.
const incomplete: ValuePoint = {x: 1};
// @ts-expect-error constructor-required field remains required.
echoValuePoint({});
// @ts-expect-error required fields reject undefined.
echoValuePoint({x: undefined});
// @ts-expect-error nonnullable defaulted field rejects null.
echoValuePoint({x: 1, y: null});
// @ts-expect-error nullable required function parameter rejects undefined.
nullableValuePoint(undefined);
// @ts-expect-error normalization input follows constructor type.
normalizeValue({total: 12});
// @ts-expect-error derived output getter is not an input parameter.
normalizeValue({total: '12', doubled: 24});
// @ts-expect-error original Dart field name is replaced by its wire name.
normalizeValue({value: '12'});
// @ts-expect-error recursive bigint policy applies to every nested int.
bigintValueNode({value: 1n, next: {value: 2}});
// @ts-expect-error ordinary recursive schema uses numbers.
echoValueNode({value: 1, next: {value: 2n}});
// @ts-expect-error output-only types do not have JS constructors.
new ValueSnapshot();
// @ts-expect-error output-only interface is a structural type, not a constructor.
new ValueRight();
// @ts-expect-error nested reference leaf cannot be structural data.
echoValueEnvelope({points: [], nodes: new Map(), names: {}, row: {$1: {x: 1}, owner: null}, owner: {value: 1}});
void [point, y, tag, nullable, normalized, total, doubled, node, branch, wideValue,
  wideNext, left, pair, snapshot, envelope, nestedRequired, incomplete];
