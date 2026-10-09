import * as api from '@napi/requests';
import { summarize as subpath } from '@napi/requests/module.wasm';
import type { Observation, Summary } from '@napi/requests';
import type { Observation as SubpathObservation, Summary as SubpathSummary } from '@napi/requests/module.wasm';

type Equal<X, Y> = (<T>() => T extends X ? 1 : 2) extends (<T>() => T extends Y ? 1 : 2) ? true : false;
type ExpectedObservation = { operation: string; durationUs: number; success: boolean };
type ExpectedSummary = { operation: string; calls: number; failed: number; totalDurationUs: number };
const exactInputAlias: Equal<Observation, ExpectedObservation> = true;
const exactOutputAlias: Equal<Summary, ExpectedSummary> = true;
const exactInput: Equal<Parameters<typeof api.summarize>[0], readonly Observation[]> = true;
const exactOutput: Equal<ReturnType<typeof api.summarize>, Summary[]> = true;
const exactSubpathInput: Equal<Observation, SubpathObservation> = true;
const exactSubpathOutput: Equal<Summary, SubpathSummary> = true;
const exactSubpathParameter: Equal<Parameters<typeof subpath>[0], readonly SubpathObservation[]> = true;
const observation: Observation = { operation: 'read', durationUs: 7, success: true };
const observations: Observation[] = [observation];
const summaries: Summary[] = api.summarize(observations);
const readonlyObservations: readonly Observation[] = observations;
const readonlyOutput: Summary[] = api.summarize(readonlyObservations);
const fromSubpath: SubpathSummary[] = subpath([{ operation: 'const', durationUs: 3, success: false }] as const);
const empty: Summary[] = api.summarize([]);
const extraFields = [{ ...observation, ignored: true }];
const structural: Summary[] = api.summarize(extraFields);
const readonlyFields: readonly Readonly<Observation>[] = Object.freeze([Object.freeze(observation)]);
const copied: Summary[] = api.summarize(readonlyFields);
copied[0].calls = 2;
copied.push({ operation: 'mutable', calls: 1, failed: 0, totalDurationUs: 1 });
fromSubpath[0].failed = 1;
for (const summary of summaries) {
  const operation: string = summary.operation;
  const calls: number = summary.calls;
  const failed: number = summary.failed;
  const total: number = summary.totalDurationUs;
  void [operation, calls, failed, total];
}
void [exactInputAlias, exactOutputAlias, exactInput, exactOutput, exactSubpathInput, exactSubpathOutput, exactSubpathParameter, readonlyOutput, empty, structural];

// @ts-expect-error Every observation field is required.
api.summarize([{ operation: 'read', durationUs: 7 }]);
// @ts-expect-error Operations retain string types.
api.summarize([{ ...observation, operation: 7 }]);
// @ts-expect-error Readonly observations retain every required field.
api.summarize([{ operation: 'read', durationUs: 7 }] as const);
// @ts-expect-error Freezing observations preserves scalar field types.
subpath(Object.freeze([{ ...observation, success: 'true' }]));
// @ts-expect-error Readonly arrays cannot contain null observations.
api.summarize([null] as const);
// @ts-expect-error Durations use numbers rather than bigint.
api.summarize([{ ...observation, durationUs: 7n }]);
// @ts-expect-error Success retains its boolean type.
subpath([{ ...observation, success: 'true' }]);
// @ts-expect-error Required fields exclude undefined.
api.summarize([{ ...observation, durationUs: undefined }]);
// @ts-expect-error The input array is nonnullable.
api.summarize(null);
// @ts-expect-error The input array cannot be undefined.
api.summarize(undefined);
// @ts-expect-error Observations are nonnullable.
api.summarize([null]);
// @ts-expect-error Only one array layer is accepted.
api.summarize([[observation]]);
// @ts-expect-error Typed arrays are not observation arrays.
api.summarize(new Uint8Array([1]));
// @ts-expect-error Inputs are materialized arrays.
api.summarize(Promise.resolve(observations));
// @ts-expect-error Summarize is synchronous.
const pending: Promise<Summary[]> = api.summarize(observations);
// @ts-expect-error Summary counts retain number types.
const invalidSummary: Summary = { operation: 'read', calls: '1', failed: 0, totalDurationUs: 7 };
// @ts-expect-error Aliases have no runtime Wasm export.
const runtimeAlias = api.Observation;
// @ts-expect-error The observation array argument is required.
api.summarize();
// @ts-expect-error Declarations check arity.
api.summarize(observations, observations);
void [pending, invalidSummary, runtimeAlias];
