import {
  check, immediate, optional, named, work, once, resolved,
  SavedSignal, WorkOwner, SignalFeed,
} from '@napi/cancellation-fixture/BACKEND';
import {check as externalCheck} from '@napi/cancellation-external/BACKEND';

const signal = new AbortController().signal;
const state: boolean = check(signal);
const same: boolean = externalCheck(signal);
const result: Promise<number> = immediate(signal);
const cooperative: Promise<number> = work(signal, 1, {ignore: false});
const nullable: boolean = optional(null);
optional(); optional(undefined); optional(signal);
named(); named({signal}); named({signal, other: null});
const iterator: AsyncIterableIterator<number, undefined, undefined> = once(signal);
const saved = new SavedSignal(signal);
saved.signal = signal;
saved.listen(() => {}); saved.remove(); saved.forget();
const owner = new WorkOwner(1);
const operation: Promise<number> = owner.work(signal, 2);
const closing: Promise<void> = owner.close();
const feed = new SignalFeed(1, {delayed: true});
const subscription: AsyncIterableIterator<number, undefined, undefined> =
  feed.watch(signal, {other: signal});
const generic: Promise<string> = resolved(signal, Promise.resolve('result'));
void [state, same, result, cooperative, nullable, iterator, operation, closing, subscription, generic];

// @ts-expect-error required signal has no implicit default
check();
// @ts-expect-error null requires a nullable Dart declaration
check(null);
// @ts-expect-error undefined does not satisfy a required native signal
immediate(undefined);
// @ts-expect-error a controller is not its signal
check(new AbortController());
// @ts-expect-error a few matching fields do not implement the standard signal
check({aborted: false});
// @ts-expect-error ordinary functions do not gain cancel methods
check.cancel();
// @ts-expect-error returned Promises do not gain synthetic cancellation
result.cancel();
// @ts-expect-error Stream accepts only the declared cancellation parameter
once(signal, {signal});
// @ts-expect-error the optional slot still requires a signal when supplied
optional(1);
// @ts-expect-error settings preserve their declared types
work(signal, 1, {ignore: 'yes'});
