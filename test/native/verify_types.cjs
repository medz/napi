'use strict';

const { copyFileSync } = require('node:fs');
const { join, resolve } = require('node:path');
const { spawnSync } = require('node:child_process');

for (const [target, fixture] of [
  ['annotated', 'annotated_functions.cts'],
  ['classes', 'annotated_classes.cts'],
  ['collections', 'annotated_collections.cts'],
  ['callbacks', 'annotated_callbacks.cts'],
  ['futures', 'annotated_futures.cts'],
  ['streams', 'annotated_streams.cts'],
]) {
  const consumer = resolve(process.argv[2], target, 'consumer.cts');
  copyFileSync(join(__dirname, fixture), consumer);
  const result = spawnSync(process.execPath, [
    require.resolve('typescript/bin/tsc'),
    '--strict', '--exactOptionalPropertyTypes', '--noEmit',
    '--module', 'NodeNext', '--target', 'ES2020', consumer,
  ], { stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}
