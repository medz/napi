import addon = require('./addon');

const sum: number = addon.add(3);
const explicit: number = addon.add(3, { step: 4 });
const point: addon.Point = addon.point;
const alias: addon.Point = addon.samePoint;
const made: addon.Point = addon.makePoint();
const absent: null = addon.absent;
const shown: number = addon.shown;
const viaHide: number = addon.viaHide;
const status: addon.Status = addon.snapshot.status;
const empty: null = addon.snapshot.empty;
const items: number[] = addon.snapshot.items;
const map: { [key: string]: number } = addon.snapshot.map;
addon.snapshot.items.push(5);
addon.snapshot.map.extra = 7;
addon.snapshot.status = addon.Status.ready;

// @ts-expect-error Module constant bindings cannot be assigned.
addon.point = made;
// @ts-expect-error Function constants retain their argument types.
addon.add('3');
// @ts-expect-error Optional named arguments exclude explicit undefined.
addon.add(3, { step: undefined });
// @ts-expect-error Constructor tear-offs retain their argument types.
addon.makePoint('3');
// @ts-expect-error Constructor defaults exclude explicit undefined.
addon.makePoint(undefined);
// @ts-expect-error Hidden re-export declarations are absent.
addon.hidden;
// @ts-expect-error Renamed declarations use the exported name.
addon.alias;
