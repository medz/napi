/** Handwritten declaration for the direct-Wasm export-kind regression fixture. */
export declare class Counter {
  private readonly __counterBrand;
  constructor(initial?: number);
  readonly value: number;
  add(delta: number): number;
}
export declare function requiredOpaque<T>(value: T): T;
export declare function optionalOpaque(): 'dart-default';
export declare function optionalOpaque<T>(value: T): T;
export declare function optionalNumber(value?: number): number;
