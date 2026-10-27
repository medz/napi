import addon = require('./addon');

const float32: globalThis.Float32Array = addon.addFloat32(new Float32Array(4));
const int32: globalThis.Int32Array = addon.addInt32(new Int32Array(4));
const float64: globalThis.Float64Array = addon.addFloat64(new Float64Array(2));
const float32List: globalThis.Float32Array = addon.echoFloat32List(new Float32Array(8));
const int32List: globalThis.Int32Array = addon.echoInt32List(new Int32Array(8));
const float64List: globalThis.Float64Array = addon.echoFloat64List(new Float64Array(4));
const subview: globalThis.Float32Array = addon.subview();
const callback: (value: globalThis.Float32Array) => globalThis.Float32Array =
  addon.bounceFloat32(value => value);

// @ts-expect-error SIMD vectors use their corresponding typed-array kind.
addon.addFloat32(new Int32Array(4));
// @ts-expect-error SIMD lists also retain their typed-array kind.
addon.echoFloat64List(new Float32Array(4));
// @ts-expect-error Plain arrays are not SIMD vectors.
addon.addInt32([1, 2, 3, 4]);
// @ts-expect-error SIMD callbacks return the matching typed-array kind.
addon.bounceFloat32(() => new Float64Array(4));
