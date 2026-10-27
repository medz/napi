import addon = require('./addon');

const buffer: globalThis.ArrayBuffer = addon.echoBuffer(new ArrayBuffer(3));
const data: globalThis.DataView = addon.echoData(new DataView(buffer));
const storedBuffer: globalThis.ArrayBuffer = addon.lastBuffer();
const storedData: globalThis.DataView = addon.lastData();
const subview: globalThis.DataView = addon.subview();
const views: (globalThis.DataView | null)[] = addon.echoViews([data, null]);
const callback: (value: globalThis.DataView) => globalThis.DataView = addon.bounceData(value => value);
addon.echoData(new DataView(new SharedArrayBuffer(3)));

// @ts-expect-error ByteBuffer inputs are ArrayBuffers, not views.
addon.echoBuffer(new Uint8Array(3));
// @ts-expect-error ByteBuffer does not accept SharedArrayBuffer directly.
addon.echoBuffer(new SharedArrayBuffer(3));
// @ts-expect-error ByteData inputs are DataViews.
addon.echoData(buffer);
// @ts-expect-error ByteData is not a typed array.
addon.echoData(new Uint8Array(3));
// @ts-expect-error Nullable view elements exclude undefined.
addon.echoViews([undefined]);
// @ts-expect-error ByteData callbacks return DataViews.
addon.bounceData(() => new ArrayBuffer(3));
