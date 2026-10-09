import { readFileSync } from 'node:fs';
import { checksum } from './dist/module.wasm';

try {
  const args = process.argv.slice(2);
  if (args.length > 1) throw new Error('Usage: node example/checksum/main.mjs [FILE|-]');
  const name = args[0] ?? '-';
  const bytes = readFileSync(name === '-' ? 0 : name);
  process.stdout.write(`${JSON.stringify(checksum({ name, bytes }))}\n`);
} catch (error) {
  process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
}
