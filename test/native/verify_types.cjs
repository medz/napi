'use strict';

const { copyFileSync } = require('node:fs');
const { join, resolve } = require('node:path');
const { spawnSync } = require('node:child_process');

const output = resolve(process.argv[2], 'annotated');
const consumer = join(output, 'consumer.cts');
copyFileSync(join(__dirname, 'annotated_functions.cts'), consumer);
const result = spawnSync(process.execPath, [
  require.resolve('typescript/bin/tsc'),
  '--strict', '--exactOptionalPropertyTypes', '--noEmit',
  '--module', 'NodeNext', '--target', 'ES2020', consumer,
], { stdio: 'inherit' });
if (result.error) throw result.error;
process.exit(result.status ?? 1);
