import {
  asyncBool, asyncInt, asyncDouble, asyncString, asyncBytes, nullableString,
  asyncVoid,
} from './dist/module.wasm';

const bool: Promise<boolean> = asyncBool(true);
const int: Promise<number> = asyncInt(42);
const double: Promise<number> = asyncDouble(0.5);
const text: Promise<string> = asyncString('relative Wasm');
const bytes: Promise<Uint8Array> = asyncBytes(new Uint8Array([1, 2]));
const nullable: Promise<string | null> = nullableString(null);
const nothing: Promise<void> = asyncVoid();
const completed: number = await asyncInt(42);
void [bool, int, double, text, bytes, nullable, nothing, completed];

// @ts-expect-error The Wasm companion declaration preserves Promise returns.
const synchronous: number = asyncInt(1);
// @ts-expect-error The Wasm companion declaration preserves input types.
asyncInt('42');
// @ts-expect-error Nullable completed results cannot become nonnullable values.
const wrong: string = await nullableString(null);

