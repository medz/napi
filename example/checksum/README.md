# File checksums in Dart and Node

Read a binary file or stdin, compute CRC32 and the byte count in one Dart Wasm
call, and print one JSON object. Node imports `checksum` directly from the
generated Wasm file and handles file I/O.

Run from the repository root with Dart 3.13.5 and a
[supported Node version](../../doc/platforms.md):

```sh
dart pub get
dart run napi:build example/checksum/checksum.dart --name @napi/checksum --out example/checksum/dist
node example/checksum/main.mjs example/checksum/sample.txt
node example/checksum/main.mjs < example/checksum/sample.txt
```

The sample contains exactly the nine ASCII bytes `123456789`, without a newline.
The file command prints `name: "example/checksum/sample.txt"`, `byteCount: 9` and
`crc32: 3421780262` (hex `cbf43926`). The checksum is an unsigned 32-bit number.
JSON property order is not part of the contract.

The exact file argument becomes `name`; it is not normalized. No argument or an
explicit `-` reads stdin and returns `name: "-"`. Empty input has byte count 0
and checksum 0. File errors, invalid arguments or more than one argument set
exit code 1, print a readable error to stderr and produce no JSON on stdout.
Node reports native import failures before the application starts and may print
its experimental Wasm warning on successful runs.

The exported types are `FileInput = { name: string; bytes: Uint8Array }` and
`FileChecksum = { name: string; byteCount: number; crc32: number }`. Node `Buffer`
is accepted. The shipped relative TypeScript consumer uses real Node types.
Starting from the repository root, check it with TypeScript 7.0.2:

```sh
cd example/checksum
npm install --no-save --no-package-lock --ignore-scripts --no-audit --no-fund @types/node@26.6.4
npx --yes --package typescript@7.0.2 tsc --strict --noEmit --target ES2022 --types node --module NodeNext --moduleResolution NodeNext --allowArbitraryExtensions consumer.mts
cd ../..
```

For npm, pack/install `example/checksum/dist` and import `checksum` from
`@napi/checksum` or `@napi/checksum/module.wasm`; these entries point to the Wasm
file. npm type resolution needs no `allowArbitraryExtensions` flag. Keep the
generated host helper beside the Wasm file. See [TypeScript](../../README.md#typescript).

This is an application teaching example: Node already provides
[`zlib.crc32`](https://nodejs.org/download/release/v22.19.0/docs/api/zlib.html#zlibcrc32data-value).
It claims no speed advantage. The application holds the whole file in memory,
pays the normal owned input-byte copy and scans the bytes once. Four CRC tables
(4 KiB total) are initialized on first use and reused. A shared-buffer view reads
little-endian four-byte words, with the original byte update for the remaining
0–3 bytes; this adds no payload copy. Only scalar fields are returned in a new
null-prototype object. Dart leaves the input unchanged. See the
[paired measurements](../../doc/performance.md#file-crc32-word-reads-0130)
for the observed speed and size tradeoffs.
CRC32 detects accidental corruption and does not authenticate content.
