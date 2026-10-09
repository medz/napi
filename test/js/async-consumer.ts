import {
  asyncBool, asyncInt, asyncDouble, asyncString, asyncBytes,
  nullableBool, nullableInt, nullableDouble, nullableString, nullableBytes,
  asyncVoid, throwBeforeFuture, asyncFailure, oversizedResult,
  nullableOversizedResult, completerSync, microtaskOrder, delayedValue,
  canceledTimer, retainBytes, readRetainedBytes, freshBytes,
  javascriptFailure, badErrorFormatter, badStackFormatter, countedAdd, calls,
} from '@napi/async';
import { asyncInt as subpathInt } from '@napi/async/module.wasm';

const bool: Promise<boolean> = asyncBool(true);
const int: Promise<number> = asyncInt(42);
const double: Promise<number> = asyncDouble(Infinity);
const text: Promise<string> = asyncString('你好');
const bytes: Promise<Uint8Array> = asyncBytes(new Uint8Array([1, 2]));
const maybeBool: Promise<boolean | null> = nullableBool(null);
const maybeInt: Promise<number | null> = nullableInt(null);
const maybeDouble: Promise<number | null> = nullableDouble(null);
const maybeText: Promise<string | null> = nullableString(null);
const maybeBytes: Promise<Uint8Array | null> = nullableBytes(null);
const nothing: Promise<void> = asyncVoid();
const thrown: Promise<number> = throwBeforeFuture('failure');
const failure: Promise<number> = asyncFailure(0);
const unsafe: Promise<number> = oversizedResult();
const nullableUnsafe: Promise<number | null> = nullableOversizedResult();
const completed: Promise<number> = completerSync(7);
const ordered: Promise<string> = microtaskOrder();
const delayed: Promise<number> = delayedValue(1);
const canceled: Promise<number> = canceledTimer();
const retained: Promise<void> = retainBytes(new Uint8Array([3]));
const read: Promise<Uint8Array> = readRetainedBytes();
const fresh: Promise<Uint8Array> = freshBytes();
const jsError: Promise<void> = javascriptFailure();
const badError: Promise<number> = badErrorFormatter();
const badStack: Promise<number> = badStackFormatter();
const sum: Promise<number> = countedAdd(1, 2);
const count: number = calls();
const subpath: Promise<number> = subpathInt(42);
const value: number = await asyncInt(42);
const nullable: string | null = await nullableString(null);
const voidValue: void = await asyncVoid();
void [bool, int, double, text, bytes, maybeBool, maybeInt, maybeDouble, maybeText,
  maybeBytes, nothing, thrown, failure, unsafe, nullableUnsafe, completed,
  ordered, delayed, canceled, retained, read, fresh, jsError, badError, badStack, sum, count,
  subpath, value, nullable, voidValue];

// @ts-expect-error Async exports return Promise rather than a completed value.
const synchronous: number = asyncInt(42);
// @ts-expect-error The resolved nullable value still requires a null check.
const nonnullable: string = await nullableString(null);
// @ts-expect-error A Promise cannot be supplied as a synchronous input.
asyncInt(Promise.resolve(42));
// @ts-expect-error Integer inputs use number rather than bigint.
asyncInt(42n);
// @ts-expect-error Boolean input does not accept a number.
asyncBool(1);
// @ts-expect-error Byte inputs require Uint8Array.
asyncBytes([1, 2]);
// @ts-expect-error Required arguments cannot be omitted.
asyncInt();
// @ts-expect-error TypeScript checks arity even though Wasm ignores extras.
asyncInt(1, 2);
// @ts-expect-error Undefined is not an accepted nullable input.
nullableInt(undefined);
// @ts-expect-error Nonnullable string input rejects null.
asyncString(null);

// @ts-expect-error Async two-argument exports require both numeric inputs.
countedAdd(1, '2');
// @ts-expect-error Async two-argument exports cannot omit the second input.
countedAdd(1);
