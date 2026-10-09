import { Buffer } from 'node:buffer';
import * as api from '@napi/checksum';
import { checksum as subpath } from '@napi/checksum/module.wasm';
import type { FileInput, FileChecksum } from '@napi/checksum';
import type { FileInput as SubpathInput, FileChecksum as SubpathChecksum } from '@napi/checksum/module.wasm';

type Equal<X, Y> = (<T>() => T extends X ? 1 : 2) extends (<T>() => T extends Y ? 1 : 2) ? true : false;
const exactInputAlias: Equal<FileInput, { name: string; bytes: Uint8Array }> = true;
const exactOutputAlias: Equal<FileChecksum, { name: string; byteCount: number; crc32: number }> = true;
const exactParameter: Equal<Parameters<typeof api.checksum>[0], FileInput> = true;
const exactResult: Equal<ReturnType<typeof api.checksum>, FileChecksum> = true;
const exactSubpathInput: Equal<FileInput, SubpathInput> = true;
const exactSubpathOutput: Equal<FileChecksum, SubpathChecksum> = true;
const input: Readonly<FileInput> = Object.freeze({ name: 'sample', bytes: Buffer.from('123456789') });
const result: FileChecksum = api.checksum(input);
const fromSubpath: SubpathChecksum = subpath({ name: 'offset', bytes: new Uint8Array([0, 1, 2]).subarray(1) } as const);
const count: number = result.byteCount;
const unsignedCrc: number = result.crc32;
result.name = 'mutable';
result.byteCount = 0;
result.crc32 = 0;
fromSubpath.crc32 = 0xcbf43926;
void [exactInputAlias, exactOutputAlias, exactParameter, exactResult, exactSubpathInput, exactSubpathOutput, count, unsignedCrc];

// @ts-expect-error Byte input fields remain required.
api.checksum({ name: 'missing' });
// @ts-expect-error Uint16Array does not satisfy Uint8Array.
subpath({ name: 'wrong', bytes: new Uint16Array(1) });
// @ts-expect-error Raw arrays are not byte views.
api.checksum({ name: 'wrong', bytes: [1, 2] });
// @ts-expect-error Nonnullable byte input excludes null.
api.checksum({ name: 'wrong', bytes: null });
// @ts-expect-error File names retain their string type.
api.checksum({ name: 1, bytes: new Uint8Array(0) });
// @ts-expect-error The native checksum returns scalar numbers, not bytes.
const returnedBytes: Uint8Array = result.crc32;
// @ts-expect-error CRC32 is a number within the unsigned32 range rather than bigint.
const bigintCrc: bigint = result.crc32;
// @ts-expect-error The application is synchronous.
const pending: Promise<FileChecksum> = api.checksum(input);
// @ts-expect-error Alias declarations do not create runtime Wasm exports.
void api.FileChecksum;
// @ts-expect-error The positional input record is required.
api.checksum();
