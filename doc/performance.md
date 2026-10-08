# Performance baseline

From the repository root, after `dart pub get`, use Dart 3.13.5 or later,
Node `^22.19.0 || >=24.5.0`, and npm:

```sh
dart run benchmark/run.dart --out benchmark/results.json
```

Default: one build per Wasm fixture, one Dart JavaScript build with `-O2`,
three runtime samples. The recorded run took **10.25 seconds wall time**.
For longer samples or a different Node binary:

```sh
dart run benchmark/run.dart --node /path/to/node \
  --iterations 200000 --warmup 20000 --runs 5 --build-runs 3 \
  --out benchmark/results.json
```

`--build-runs` defaults to one: its build median is a single observation, with
no build variance estimate. Temporary outputs are removed after the run.
Existing SDK/pub/npm/filesystem caches are uncontrolled. No new dependency,
benchmark framework, or ordinary correctness CI timing assertion is required.

## Recorded environment

[`benchmark/baseline.json`](../benchmark/baseline.json) contains all samples,
inputs, iteration/warmup counts, minimums, maximums, medians, and spread.
This is a 0.2.0 development baseline, not a performance guarantee.

- Dart 3.13.5 stable, macos_arm64.
- Node 26.0.0, V8 14.6.202.33-node.19; npm 11.12.1 (verified after the run).
- Apple M3 Max, arm64; macOS 27.0.1, build 26A434.
- Three samples; small sync cases use 20,000 calls and 2,000 warmup calls.
- Small async/error cases use 2,000 calls and 200 warmup calls.

This Node 26 measurement is separate from the Node 22.19 correctness suite;
the numbers below were not measured on Node 22.19.

## Build and size

Build time includes `dart run napi:build`, analysis, Wasm compilation, import
rewriting, and host/declaration/package generation. npm packing is separate.
Final packages contain two declaration copies, for package and direct Wasm imports.

| Fixture | Build ms, one sample | Wasm bytes | Host bytes | Each declaration bytes | npm .tgz bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| `minimal`: `int answer()` | 2,364.53 | 17,161 | 16,552 | 42 | 9,553 |
| `minimal_async`: `Future<int> answer()` | 2,309.65 | 29,671 | 18,956 | 51 | 15,559 |
| `api`: sync/async numeric, string, bytes, errors | 2,420.17 | 38,316 | 23,049 | 686 | 19,392 |

The Dart JavaScript comparison compiled in 352.47 ms and produced 68,051 bytes,
or 21,435 bytes using `dart:io` gzip. That gzip stream is not an npm package and
includes neither a manifest nor napi declarations.

## Native import

Each sample starts a fresh Node process and imports the raw `.wasm` ES module.
The companion `.imports.mjs` is a native dependency; there is no custom loader
or manual WebAssembly initialization in the consumer. Import timing excludes
process startup. Filesystem caches are uncontrolled: cold means a fresh process
and module instance. The first call is separate and includes `await` (also for
synchronous results) and the result assertion.

| Fixture | Import median ms | Import min–max ms | First call median ms |
| --- | ---: | ---: | ---: |
| `minimal` | 2.283 | 2.255–2.590 | 0.080 |
| `minimal_async` | 2.632 | 2.490–2.776 | 0.604 |
| `api` | 2.978 | 2.954–3.234 | 0.175 |

## Warmed calls

Selected medians, in **nanoseconds per completed call**. The report retains
all samples and variation. Order rotates between implementations; JIT/GC remain
uncontrolled. Timings include loop/dispatch/result consumption, checks, and copies,
rather than isolating an FFI transition. Async cases await each call sequentially,
without concurrent batching.

| Case | Calls/sample | Wasm ns | JavaScript ns | Dart JavaScript ns |
| --- | ---: | ---: | ---: | ---: |
| Numeric add | 20,000 | 96.0 | 20.0 | 37.6 |
| Safe 53-bit integer echo | 20,000 | 44.1 | 18.1 | 35.7 |
| Future numeric add | 2,000 | 737.0 | 157.7 | 14,028.1 |
| String echo, 16 UTF-16 units | 20,000 | 57.5 | 19.3 | 32.5 |
| String length, 1,024 UTF-16 units | 1,250 | 84.1 | 28.4 | 40.4 |
| String echo, 65,536 UTF-16 units | 50 | 92.5 | 35.8 | 50.8 |
| Uint8Array echo, 32 bytes | 20,000 | 217.1 | 69.0 | 98.9 |
| Buffer echo, 1,024 bytes | 1,250 | 467.1 | 367.7 | 466.6 |
| Subarray echo, 65,536 bytes | 50 | 8,232.5 | 4,273.3 | 8,840.0 |
| Byte sum, 65,536 bytes | 50 | 69,749.2 | 294,445.8 | 44,094.2 |
| Async bytes echo, 1,024 bytes | 125 | 894.7 | 401.0 | 15,172.0 |
| Invalid number, caught TypeError | 2,000 | 24,962.9 | 9,893.2 | — |
| Repeated business error | 2,000 | 26,372.0 | 9,735.3 | — |
| Repeated rejected Future | 2,000 | 9,924.6 | 10,787.4 | — |

Strings repeat `A`, `é`, a non-BMP character, and an isolated surrogate. Echo
and length do not transform or copy every UTF-16 unit: immutable strings can
remain shared references. These rows measure boundary operations, not text
allocation or processing bandwidth.

Bytes repeat `i & 255`. Uint8Array, Buffer, and offset subarrays are tested at
32/1,024/65,536 bytes. Echo includes independent input/output copies; sum includes
one input copy and reads each byte. Preflight checks verify independent outputs
and async input snapshots for all implementations. Large-input iterations are
scaled down to keep default cost bounded.

The JavaScript comparison includes type/brand checks, integer checks, and the
same ownership copy counts. Dart JavaScript runs the same business code with a
small `dart:js_interop` entry, JavaScript input checks, and explicit copies.
Its binding and Future scheduling differ from the generated napi Wasm binding.
Dart JavaScript error mapping is omitted. Wasm errors preserve Dart diagnostic
information that the plain JavaScript comparison does not provide.

Some short cases have wide spread: Wasm Buffer echo at 1,024 bytes showed 139.9%,
and subarray echo at 65,536 bytes showed 90.9%. Spread is `(max - min) / median *
100`, not a confidence interval. Increase counts and repeat on the same environment
before treating changes as improvements. No optimization was made from this run.
