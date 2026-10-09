import { summarize } from './dist/module.wasm';
import type { Observation, Summary } from './dist/module.wasm';

const observations: Observation[] = [
  { operation: 'GET /articles', durationUs: 800, success: true },
  { operation: 'GET /articles', durationUs: 200, success: false },
];
const summaries: Summary[] = summarize(observations);
for (const summary of summaries) {
  const calls: number = summary.calls;
  const failed: number = summary.failed;
  const totalDurationUs: number = summary.totalDurationUs;
  console.log(summary.operation, calls, failed, totalDurationUs);
}
