import addon = require('./addon');

const ready: addon.Status = addon.Status.ready;
const done: addon.Status = addon.toggle(ready);
const numeric: 0 | 1 = done;
const mode: addon.Mode = addon.Mode.fast;
const code: number = addon.modeCode(mode);
const defaultStatus: addon.Status = addon.defaultStatus();
const nullable: addon.Status | null = addon.nullableStatus();
const job = new addon.Job(ready);
job.status = done;
job.next = null;
const finished: addon.Status = job.finish();
const list: (addon.Status | null)[] = addon.echoStatuses([ready, null, done]);
const record: { status: addon.Status; next: addon.Status | null } =
  addon.statusRecord({ status: ready, next: null });
const applied: addon.Status = addon.applyStatus(ready, () => done);
const future: Promise<addon.Status> = addon.futureStatus(Promise.resolve(done));
const stream: AsyncIterableIterator<addon.Status> = addon.statuses();

// @ts-expect-error Exported enum members are readonly.
addon.Status.ready = 1;
// @ts-expect-error Numeric enum inputs are limited to declared indices.
addon.echoStatus(2);
// @ts-expect-error Enum inputs are numeric, not case names.
addon.echoStatus('ready');
// @ts-expect-error Enum objects do not provide numeric reverse mappings.
addon.Status[0];
// @ts-expect-error Private Dart case names are not exported.
addon.Mode._quick;
// @ts-expect-error Enhanced enum data stays in Dart.
addon.Mode.code;
// @ts-expect-error Optional enum arguments exclude undefined.
addon.defaultStatus(undefined);
// @ts-expect-error Nullable enum values exclude undefined.
addon.nullableStatus(undefined);
// @ts-expect-error Class members retain their enum type.
job.status = 2;
// @ts-expect-error Nullable record enum fields are still required.
addon.statusRecord({ status: ready });
// @ts-expect-error Callback results must be a declared enum value.
addon.applyStatus(ready, () => 2);
