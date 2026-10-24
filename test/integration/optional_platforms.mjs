import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {createServer} from 'node:http';
import {readFile, writeFile, mkdir, rm, readdir} from 'node:fs/promises';
import {dirname, join} from 'node:path';
import {promisify} from 'node:util';

const run = promisify(execFile);
const npm = process.platform === 'win32'
  ? [process.execPath, join(dirname(process.execPath), 'node_modules/npm/bin/npm-cli.js')]
  : ['npm'];
const root = process.argv[2];
const scratch = join(root, `consumer-${process.version}`);
const entryName = JSON.parse(await readFile(join(root, 'package', 'package.json'))).name;
await mkdir(scratch);
const manifests = new Map();
const tarballs = new Map();
const downloaded = [];
for (const name of await readdir(root)) {
  if (name.startsWith('consumer-') || name.startsWith('.')) continue;
  const directory = join(root, name);
  const manifest = JSON.parse(await readFile(join(directory, 'package.json')));
  const {stdout} = await run(npm[0], [
    ...npm.slice(1), 'pack', '--ignore-scripts', '--json', '--pack-destination', scratch,
  ], {cwd: directory});
  const [packed] = JSON.parse(stdout);
  manifests.set(manifest.name, {...manifest, dist: {
    integrity: packed.integrity, shasum: packed.shasum, filename: packed.filename,
  }});
  tarballs.set(packed.filename, {
    name: manifest.name, bytes: await readFile(join(scratch, packed.filename)),
  });
}
const server = createServer((request, response) => {
  const pathname = decodeURIComponent(new URL(request.url, 'http://localhost').pathname);
  if (pathname.startsWith('/tarballs/')) {
    const tarball = tarballs.get(pathname.slice('/tarballs/'.length));
    if (!tarball) { response.writeHead(404).end(); return; }
    downloaded.push(tarball.name);
    response.writeHead(200, {'content-type': 'application/octet-stream'}).end(tarball.bytes);
    return;
  }
  const manifest = manifests.get(pathname.slice(1));
  if (!manifest) { response.writeHead(404).end('{}'); return; }
  const version = {...manifest, dist: {...manifest.dist,
    tarball: `${registry}tarballs/${manifest.dist.filename}`,
  }};
  response.writeHead(200, {'content-type': 'application/json'}).end(JSON.stringify({
    name: manifest.name, 'dist-tags': {latest: manifest.version},
    versions: {[manifest.version]: version},
  }));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const registry = `http://127.0.0.1:${server.address().port}/`;
const entry = manifests.get(entryName);
const selected = [...manifests.values()].find(p =>
  p.os?.includes(process.platform) && p.cpu?.includes(process.arch));
assert.ok(selected, 'test host must have a native fixture');
try {
  await writeFile(join(scratch, 'package.json'), '{"private":true,"type":"module"}');
  await run(npm[0], [...npm.slice(1), 'install', `${entry.name}@${entry.version}`,
    '--registry', registry, '--cache', join(scratch, 'cache'),
    '--ignore-scripts', '--no-audit', '--no-fund',
  ], {cwd: scratch});
  assert.deepEqual(downloaded.sort(), [entry.name, selected.name].sort());
  const consumer = `
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
const require = createRequire(import.meta.url);
const first = process.argv[2] === 'cjs' ? require(${JSON.stringify(entryName)}) : await import(${JSON.stringify(entryName)});
const second = process.argv[2] === 'cjs' ? await import(${JSON.stringify(entryName)}) : require(${JSON.stringify(entryName)});
assert.equal(first.Counter, second.Counter);
assert.equal(require(${JSON.stringify(entryName + '/native')}).Counter, first.Counter);
const counter = new first.Counter();
const firstValue = counter.increment();
assert.equal(counter.increment(), firstValue + 1);
assert.ok(counter instanceof second.Counter);
`;
  await writeFile(join(scratch, 'check.mjs'), consumer);
  for (const order of ['cjs', 'esm']) {
    await run(process.execPath, ['check.mjs', order], {cwd: scratch});
  }
  const payload = join(scratch, 'node_modules', selected.name);
  await writeFile(join(payload, 'module.mjs'), 'throw new Error("binding failed");');
  await writeFile(join(scratch, 'broken.mjs'), `
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
const require = createRequire(import.meta.url);
assert.throws(() => require(${JSON.stringify(entryName)}), /binding failed/);
`);
  await run(process.execPath, ['broken.mjs'], {cwd: scratch});
  await rm(join(payload, 'module.mjs'));
  await writeFile(join(scratch, 'broken-entry.mjs'), `
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
const require = createRequire(import.meta.url);
assert.throws(() => require(${JSON.stringify(entryName)}), error =>
  error.code === 'MODULE_NOT_FOUND' && error.message.includes('module.mjs'));
`);
  await run(process.execPath, ['broken-entry.mjs'], {cwd: scratch});
  await rm(payload, {recursive: true});
  await writeFile(join(scratch, 'missing.mjs'), `
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
const require = createRequire(import.meta.url);
assert.throws(() => require(${JSON.stringify(entryName)}), error =>
  error.message.includes(${JSON.stringify(selected.name + '@' + selected.version)}) &&
  error.message.includes('optional dependencies') && error.cause.code === 'MODULE_NOT_FOUND');
`);
  await run(process.execPath, ['missing.mjs'], {cwd: scratch});
} finally {
  await new Promise(resolve => server.close(resolve));
}
