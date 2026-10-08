# Performance baseline

From the repository root, after `dart pub get`, use Dart 3.13.5 or later,
Node `^22.19.0 || >=24.5.0`, and npm:

```sh
dart run benchmark/run.dart --out benchmark/results.json
```

Default: one build per Wasm fixture, one Dart JavaScript build with `-O2`,
three runtime samples. The recorded run took **10.91 seconds wall time**.
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
This is a 0.2.0 baseline, not a performance guarantee.

- Dart 3.13.5 stable, macos_arm64.
- Node 26.0.0, V8 14.6.202.33-node.19; npm 11.12.1.
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
| `minimal`: `int answer()` | 2,322.01 | 17,295 | 16,611 | 42 | 9,613 |
| `minimal_async`: `Future<int> answer()` | 2,625.60 | 29,671 | 18,956 | 51 | 15,559 |
| `api`: sync/async numeric, string, bytes, errors | 2,419.86 | 38,272 | 23,049 | 686 | 19,379 |

The Dart JavaScript comparison compiled in 380.12 ms and produced 68,051 bytes,
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
| `minimal` | 2.326 | 2.311–2.351 | 0.111 |
| `minimal_async` | 2.505 | 2.449–2.579 | 0.607 |
| `api` | 3.207 | 3.119–3.663 | 0.190 |

## Warmed calls

Selected medians, in **nanoseconds per completed call**. The report retains
all samples and variation. Order rotates between implementations; JIT/GC remain
uncontrolled. Timings include loop/dispatch/result consumption, checks, and copies,
rather than isolating an FFI transition. Async cases await each call sequentially,
without concurrent batching.

| Case | Calls/sample | Wasm ns | JavaScript ns | Dart JavaScript ns |
| --- | ---: | ---: | ---: | ---: |
| Numeric add | 20,000 | 97.8 | 21.0 | 43.4 |
| Safe 53-bit integer echo | 20,000 | 46.5 | 18.7 | 38.0 |
| Future numeric add | 2,000 | 819.8 | 179.2 | 14,881.7 |
| String echo, 16 UTF-16 units | 20,000 | 64.0 | 19.0 | 32.9 |
| String length, 1,024 UTF-16 units | 1,250 | 81.6 | 25.4 | 40.8 |
| String echo, 65,536 UTF-16 units | 50 | 77.5 | 27.5 | 40.8 |
| Uint8Array echo, 32 bytes | 20,000 | 230.4 | 68.4 | 100.9 |
| Buffer echo, 1,024 bytes | 1,250 | 420.7 | 466.5 | 475.8 |
| Subarray echo, 65,536 bytes | 50 | 2,612.5 | 2,598.3 | 2,519.2 |
| Byte sum, 65,536 bytes | 50 | 63,780.8 | 299,070.8 | 40,786.7 |
| Async bytes echo, 1,024 bytes | 125 | 1,020.7 | 475.7 | 15,417.7 |
| Invalid number, caught TypeError | 2,000 | 26,038.5 | 9,787.3 | — |
| Repeated business error | 2,000 | 26,809.0 | 9,645.9 | — |
| Repeated rejected Future | 2,000 | 9,986.4 | 10,661.0 | — |

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

Some short cases have wide spread: Wasm Buffer echo at 1,024 bytes showed 225.5%,
and Uint8Array echo at 65,536 bytes showed 246.3%. Spread is `(max - min) / median *
100`, not a confidence interval. Increase counts and repeat on the same environment
before treating changes as improvements. No optimization was made from this run.
