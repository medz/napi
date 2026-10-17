import * as api from '@napi/native-events-fixture';
import * as direct from '@napi/native-events-fixture/native';

const snapshot: string = api.readEvents();
const scheduled: void = api.startTimer(30, 'example');
const pending: void = api.leaveFuturePending();
const directSnapshot: string = direct.readEvents();
// @ts-expect-error synchronous exports do not become Promise declarations.
const promise: Promise<void> = api.enqueueMicrotasks();
// @ts-expect-error the timer delay retains its strict numeric input.
api.startTimer('30', 'example');
// @ts-expect-error public signatures retain required arguments.
api.sendMessages();
void [snapshot, scheduled, pending, directSnapshot, promise];
