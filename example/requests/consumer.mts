import { summarize } from './dist/module.wasm';
import type { Observation, Summary } from './dist/module.wasm';

const observations = [
  { operation: 'GET /articles', durationUs: 800, success: true },
  { operation: 'GET /articles', durationUs: 200, success: false },
] as const satisfies readonly Observation[];
const input: readonly Observation[] = observations;
const summaries: Summary[] = summarize(input);
for (const summary of summaries) {
  const calls: number = summary.calls;
  const failed: number = summary.failed;
  const totalDurationUs: number = summary.totalDurationUs;
  console.log(summary.operation, calls, failed, totalDurationUs);
}
