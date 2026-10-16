// Handwritten boundary fixture. The public entry is module.wasm.
import * as dart from './core.wasm';
import {useDefault} from './arguments.mjs';

function int32(value, name) {
  if (typeof value !== 'number' || !Number.isInteger(value)
      || value < -2147483648 || value > 2147483647) {
    throw new TypeError(`${name} must be a signed 32-bit integer`);
  }
  return value;
}

// A private field retains the actual externalized Dart Counter object.
// Each linked module graph owns a distinct class/private-field brand.
export class Counter {
  #reference;
  constructor(initial = 0) {
    this.#reference = dart.counterNew(int32(initial, 'initial'));
  }
  get value() {
    return dart.counterValue(this.#reference);
  }
  add(delta) {
    int32(delta, 'delta');
    // Prevent ABI truncation before mutating the underlying Dart object.
    int32(dart.counterValue(this.#reference) + delta, 'result');
    return dart.counterAdd(this.#reference, delta);
  }
}

// Count arguments before lowering to the fixed-arity Wasm ABI.
export function requiredOpaque(value) {
  useDefault(value, arguments.length > 0, 'opaqueRequired', 'requiredOpaque');
  return dart.requiredOpaqueCall(value);
}

export function optionalOpaque(value) {
  return dart.optionalOpaqueCall(
    useDefault(value, arguments.length > 0, 'opaqueOptional', 'optionalOpaque') ? 0 : 1, value);
}

export function optionalNumber(value) {
  // An ordinary optional Dart value defaults for both omission and undefined.
  if (useDefault(value, arguments.length > 0, 'optional', 'optionalNumber')) return dart.optionalNumberCall(0, 0);
  return dart.optionalNumberCall(1, int32(value, 'value'));
}
