import { readFileSync } from 'node:fs';
import { summarize } from './dist/module.wasm';

try {
  const observations = [];
  const lines = readFileSync(0, 'utf8').split('\n');
  for (const [index, line] of lines.entries()) {
    if (line.trim() === '') continue;
    try {
      observations.push(JSON.parse(line));
    } catch (error) {
      throw new Error(`Invalid JSON on line ${index + 1}: ${error.message}`);
    }
  }
  process.stdout.write(`${JSON.stringify(summarize(observations))}\n`);
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
}
