import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { crc32 } from 'node:zlib';
import * as api from '@napi/checksum';
import { checksum as subpath } from '@napi/checksum/module.wasm';
import { checksum as relative } from './dist/module.wasm';

assert.equal(typeof api.checksum, 'function');
assert.equal(api.checksum, subpath);
assert.equal(api.checksum, relative);
assert.match(Function.prototype.toString.call(api.checksum), /\[native code\]/);
const names = ['checksum'];
const nativeFunctions = names.length;
for (const name of ['FileInput', 'FileChecksum']) assert.equal(Object.hasOwn(api, name), false);
let checks = 0;
let cliChecks = 0;

function checksum(name, bytes) {
  const before = new Uint8Array(bytes);
  const expected = { name, byteCount: bytes.byteLength, crc32: crc32(bytes) };
  const input = Object.freeze({ name, bytes });
  checks++;
  const output = api.checksum(input);
  assert.equal(Object.getPrototypeOf(output), null);
  assert.deepEqual({ ...output }, expected);
  assert(Number.isSafeInteger(output.byteCount) && output.byteCount >= 0);
  assert(Number.isSafeInteger(output.crc32) && output.crc32 >= 0 && output.crc32 <= 0xffffffff);
  for (const key of ['name', 'byteCount', 'crc32']) {
    const field = Object.getOwnPropertyDescriptor(output, key);
    assert(Object.hasOwn(field, 'value') && field.writable && field.enumerable && field.configurable);
  }
  assert.equal(input.name, name);
  assert.deepEqual(new Uint8Array(bytes), before, 'checksum does not change caller bytes');
  return output;
}

const sample = readFileSync(new URL('./sample.txt', import.meta.url));
assert.deepEqual(sample, Buffer.from('123456789'));
assert.equal(checksum('', new Uint8Array(0)).crc32, 0);
const standard = checksum('sample', sample);
assert.equal(standard.byteCount, 9);
assert.equal(standard.crc32, 0xcbf43926);
assert(standard.crc32 > 0x7fffffff, 'CRC32 keeps its unsigned high bit');
standard.name = 'changed output';
standard.byteCount = 0;
standard.crc32 = 0;
assert.deepEqual(sample, Buffer.from('123456789'));
const binary = Uint8Array.from({ length: 256 }, (_, index) => index);
checksum('binary', binary);
const backing = Buffer.alloc(binary.length + 4, 0xa5);
backing.set(binary, 2);
const offset = backing.subarray(2, 2 + binary.length);
assert(offset.byteOffset > 0);
checksum('  文件 🚀 e\u0301 \ud800  ', offset);
assert.equal(backing[1], 0xa5);
assert.equal(backing[2 + binary.length], 0xa5);

for (const length of [...Array.from({ length: 20 }, (_, index) => index), 63, 64, 65, 255, 256, 257]) {
  const data = Uint8Array.from({ length }, (_, index) => (index * 31 + length * 7) & 0xff);
  checksum(`tail-${length}`, data);
  const position = length % 4 + 1;
  const storage = Buffer.alloc(length + position + 4, 0xa5);
  storage.set(data, position);
  checksum(`offset-${length}`, storage.subarray(position, position + length));
  assert.equal(storage[position - 1], 0xa5);
  assert.equal(storage[position + length], 0xa5);
}

const cwd = fileURLToPath(new URL('.', import.meta.url));
const main = fileURLToPath(new URL('./main.mjs', import.meta.url));
function cli(args, input) {
  cliChecks++;
  const result = spawnSync(process.execPath, ['--disable-warning=ExperimentalWarning', main, ...args], {
    cwd, input, encoding: 'utf8', timeout: 10000,
  });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  return result;
}
function cliSuccess(args, input, name, bytes) {
  const result = cli(args, input);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stderr, '');
  assert.equal(result.stdout.indexOf('\n'), result.stdout.length - 1, 'CLI writes one JSON line');
  assert.deepEqual(JSON.parse(result.stdout), { name, byteCount: bytes.byteLength, crc32: crc32(bytes) });
}
function cliFailure(args, message) {
  const result = cli(args);
  assert.equal(result.status, 1);
  assert.equal(result.stdout, '', 'failed CLI produces no partial JSON');
  assert.match(result.stderr, message);
}

cliSuccess(['sample.txt'], undefined, 'sample.txt', sample);
cliSuccess([], sample, '-', sample);
const smokeCliChecks = cliChecks;
if (process.version === 'v22.19.0') {
  const temporary = mkdtempSync(join(tmpdir(), 'napi-checksum-cli-'));
  try {
    const emptyPath = join(temporary, 'empty.bin');
    writeFileSync(emptyPath, Buffer.alloc(0));
    cliSuccess([emptyPath], undefined, emptyPath, Buffer.alloc(0));
    const binaryPath = join(temporary, 'binary.bin');
    writeFileSync(binaryPath, binary);
    cliSuccess([binaryPath], undefined, binaryPath, binary);
    const unicodePath = join(temporary, '文件 with space 🚀.bin');
    writeFileSync(unicodePath, sample);
    cliSuccess([unicodePath], undefined, unicodePath, sample);
    cliSuccess(['-'], binary, '-', binary);
    cliFailure([join(temporary, 'missing.bin')], /ENOENT/);
    cliFailure(['sample.txt', 'extra'], /^Usage:/);
  } finally { rmSync(temporary, { recursive: true, force: true }); }
}
console.log(JSON.stringify({ checks, cliChecks, extraCliChecks: cliChecks - smokeCliChecks, nativeFunctions, node: process.version }));
