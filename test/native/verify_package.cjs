'use strict';

const assert = require('node:assert/strict');
const { copyFileSync, existsSync, mkdtempSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join, resolve } = require('node:path');
const { spawnSync } = require('node:child_process');
const { pathToFileURL } = require('node:url');

const source = resolve(process.argv[2]);
const npm = process.env.npm_execpath;
assert(npm, 'Run through npm run verify-package so the npm CLI is explicit');
const temporary = mkdtempSync(join(tmpdir(), 'napi-npm-consumer-'));

function run(script, args, cwd) {
  const result = spawnSync(process.execPath, [script, ...args], {
    cwd, encoding: 'utf8',
  });
  if (result.error) throw result.error;
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`);
  return result.stdout;
}

function pack(directory) {
  const [packed] = JSON.parse(run(npm, [
    'pack', '--json', '--offline', '--ignore-scripts', '--pack-destination', temporary,
  ], directory));
  return packed;
}

async function main() {
  try {
    assert(existsSync(join(source, '.napi.json')));
    const metadata = JSON.parse(readFileSync(join(source, 'package.json'), 'utf8'));
    const multi = metadata.optionalDependencies !== undefined;
    const hostPackages = [];
    if (multi) {
      const names = [];
      for (const platform of readdirSync(join(source, 'platforms'))) {
        const directory = join(source, 'platforms', platform);
        const leaf = JSON.parse(readFileSync(join(directory, 'package.json'), 'utf8'));
        assert.equal(leaf.version, metadata.version);
        assert.equal(metadata.optionalDependencies[leaf.name], metadata.version);
        names.push(leaf.name);
        const packed = pack(directory);
        assert.deepEqual(packed.files.map(file => file.path).sort(), [
          'NOTICES', 'addon.node', 'index.d.cts', 'package.json',
        ].sort());
        if (leaf.os.includes(process.platform) && leaf.cpu.includes(process.arch)) {
          hostPackages.push(join(temporary, packed.filename));
        }
      }
      assert.deepEqual(names.sort(), Object.keys(metadata.optionalDependencies).sort());
      assert.equal(hostPackages.length, 1, 'Expected one native package for this host');
      const cjs = require(source);
      const esm = await import(pathToFileURL(join(source, 'index.mjs')).href);
      assert.equal(esm.default, cjs);
      assert.equal(esm.Counter, cjs.Counter);
      const counter = new cjs.Counter(5);
      assert(counter instanceof esm.Counter);
      assert.equal(counter.same(), counter);
      assert.equal(esm.Counter.prototype.increment.call(counter), 6);
    }
    const packed = pack(source);
    const expected = [
      'NOTICES', 'index.cjs', 'index.d.cts', 'index.d.mts', 'index.mjs', 'package.json',
    ];
    if (!multi) expected.push('addon.node');
    assert.deepEqual(packed.files.map(file => file.path).sort(), expected.sort());
    const consumer = join(temporary, 'consumer');
    mkdirSync(consumer);
    writeFileSync(join(consumer, 'package.json'), JSON.stringify({
      name: 'napi-package-consumer', private: true, type: 'module',
    }));
    run(npm, [
      'install', '--offline', '--ignore-scripts', '--no-audit', '--no-fund',
      join(temporary, packed.filename), ...hostPackages,
    ], consumer);
    for (const extension of ['cjs', 'cts', 'mts']) {
      copyFileSync(join(__dirname, `package_consumer.${extension}`),
        join(consumer, `consumer.${extension}`));
    }
    run(join(consumer, 'consumer.cjs'), [], consumer);
    run(require.resolve('typescript/bin/tsc'), [
      '--strict', '--exactOptionalPropertyTypes', '--noEmit',
      '--module', 'NodeNext', '--target', 'ES2020',
      join(consumer, 'consumer.cts'), join(consumer, 'consumer.mts'),
    ], consumer);
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}

main().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
