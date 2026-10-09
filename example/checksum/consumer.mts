import { Buffer } from 'node:buffer';
import { checksum } from './dist/module.wasm';
import type { FileInput, FileChecksum } from './dist/module.wasm';

const input = { name: 'sample', bytes: Buffer.from('123456789') } as const satisfies FileInput;
const result: FileChecksum = checksum(input);
const byteCount: number = result.byteCount;
const crc32: number = result.crc32;
result.name = 'mutable';
void [byteCount, crc32];

// @ts-expect-error Bytes are required.
checksum({ name: 'missing' });
// @ts-expect-error Other typed-array brands are not byte views.
checksum({ name: 'wrong', bytes: new Uint16Array(1) });
// @ts-expect-error The checksum is a number, not returned binary content.
const returnedBytes: Uint8Array = result.crc32;
