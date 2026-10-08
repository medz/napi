# Performance measurements

Run from the repository root with Dart 3.13.5 or later, Node
`^22.19.0 || >=24.5.0`, and npm:

```sh
dart run benchmark/run.dart --out benchmark/results.json
```

Defaults: one build per fixture, three runtime/import samples, 20,000 small sync
calls, and 2,000 warmup calls. The recorded **0.3.0** run used five samples:

```sh
dart run benchmark/run.dart --runs 5 --out benchmark/baseline.json
```

It took **36.31 seconds wall time**. Each build median is a single observation
without a build variance estimate. Increase `--iterations`, `--warmup`, `--runs`,
and `--build-runs` for longer investigations. Temporary outputs are removed;
SDK/pub/npm/filesystem caches, JIT and GC are uncontrolled. No new dependency,
benchmark framework, or correctness CI timing threshold is required.

## Recorded environment

[`benchmark/baseline.json`](../benchmark/baseline.json) retains every sample,
input, count, median, minimum, maximum, and spread. These are observations,
not performance guarantees.

- Dart SDK version: 3.13.5 (stable) (Tue Sep 29 01:00:52 2026 -0700) on "macos_arm64".
- v26.0.0, V8 14.6.202.33-node.19; npm 11.12.1.
- Apple M3 Max, arm64; Version 27.0.1 (Build 26A434).
- Five runtime/import samples; one build per fixture.

Node 26 timings are separate from the Node 22.19 correctness suite.

## Build and size

Build time includes analysis, compilation, rewriting and package generation.
npm packing is separate. Each package includes two identical declaration copies.

| Fixture | Build ms | Wasm bytes | Host bytes | Each declaration bytes | npm .tgz bytes |
| --- | ---: | ---: | ---: | ---: | ---: |
| `minimal` | 2,223.15 | 17,295 | 16,703 | 42 | 9,650 |
| `minimal_async` | 2,248.61 | 29,671 | 19,048 | 51 | 15,594 |
| `api` | 2,324.37 | 38,272 | 23,141 | 686 | 19,417 |
| `collections` | 2,377.48 | 49,019 | 28,121 | 431 | 24,736 |

`minimal` exports a synchronous answer; `minimal_async` exports its Future.
`api` measures numeric/string/bytes/errors. `collections` exports List<int>
echo/sum, Map<String,String> echo, both async echoes, and a scalar answer.

All three scalar/bytes fixtures emitted **zero collection host helpers**,
read from their generated files. Their Wasm sizes match the 0.2.0 baseline.
Each host grew 92 bytes for safe JS exception stack extraction.

The Dart JavaScript comparison uses `-O2`: 324.51 ms, 68,051 raw
bytes and 21,435 gzip bytes. This gzip stream is not an npm package
and includes no napi manifest or declarations.

## Native import

Each sample starts a fresh Node process and imports the raw Wasm ES module;
host helpers load as native dependencies. Import timing excludes process startup.
Filesystem caches are uncontrolled: cold means a fresh process/module instance.
First-call timing ends on the synchronous result or Promise completion, before
the assertion. Unlike 0.2.0, it adds no await to synchronous calls and excludes
the result assertion.

| Fixture | Import median ms | Import min–max ms | First completed call ms |
| --- | ---: | ---: | ---: |
| `minimal` | 2.102 | 2.052–2.380 | 0.068 |
| `minimal_async` | 2.361 | 2.138–2.412 | 0.564 |
| `api` | 2.763 | 2.734–3.045 | 0.141 |
| `collections` | 2.784 | 2.761–3.491 | 0.046 |

## Warmed scalar and byte calls

Selected medians in **nanoseconds per completed call**:

| Case | Calls/sample | Wasm ns | JavaScript ns | Dart JavaScript ns |
| --- | ---: | ---: | ---: | ---: |
| `numeric/add` | 20,000 | 84.2 | 19.2 | 33.5 |
| `numeric/int-safe53` | 20,000 | 50.6 | 18.7 | 34.9 |
| `async/add` | 2,000 | 800.0 | 205.8 | 14106.5 |
| `string/echo/16` | 20,000 | 48.5 | 12.1 | 28.0 |
| `bytes/echo/Uint8Array/1024` | 1,250 | 491.2 | 382.7 | 433.8 |
| `bytes/sum/65536` | 50 | 63860.8 | 288450.0 | 40543.3 |

## Collection conversions

Selected medians in **microseconds per completed call**:

| Case | Calls/sample | Wasm µs | JavaScript µs | Wasm spread % |
| --- | ---: | ---: | ---: | ---: |
| `list/echo/int/0` | 20,000 | 0.056 | 0.028 | 75.7 |
| `map/echo/string/0` | 20,000 | 0.128 | 0.095 | 28.2 |
| `list/echo/int/16` | 20,000 | 5.064 | 0.754 | 3.2 |
| `map/echo/string/16` | 20,000 | 9.817 | 1.473 | 3.7 |
| `list/echo/int/256` | 5,000 | 77.985 | 11.995 | 1.8 |
| `map/echo/string/256` | 5,000 | 156.872 | 23.412 | 1.1 |
| `list/echo/int/4096` | 312 | 1,242.217 | 187.932 | 0.9 |
| `list/sum/int/4096` | 312 | 786.093 | 188.013 | 4.2 |
| `map/echo/string/4096` | 312 | 2,592.298 | 453.008 | 1.8 |
| `async/list-echo/int/4096` | 50 | 1,231.824 | 189.008 | 2.5 |
| `async/map-echo/string/4096` | 50 | 2,588.182 | 457.537 | 6.4 |

All collection cases include 0/1/16/256/4096 elements. Lists use safe integers
`i & 255`; Maps use `keyN` keys and UTF-16 values with a non-BMP character and an
isolated surrogate. Echo validates own-data descriptors and copies input/output
containers. Sum makes one input copy and visits every element. Async calls await
sequentially, without concurrent batching.

`ownership_copies` counts input/output ownership boundaries, not physical
allocations. Wasm additionally creates a temporary JS descriptor snapshot and
Dart List/Map storage. The JS reference validates these measured ordinary dense
Arrays/null-prototype objects and returns independent containers. It is not a
second implementation of the complete cross-realm/Proxy/error contract. Dart
JavaScript collection timings are omitted because no equivalent collection
binding is implemented in this benchmark.

Large collection conversions dominate these trivial echo operations. This does
not establish that a small collection transform benefits from Wasm. Batch useful
work per call and measure the actual workload. No optimization is claimed.

## Scope and interpretation

Timings include loop, dispatch, result consumption, validation, allocation and
copies. Implementation order rotates. Preflight checks verify sync independence
and async call-time snapshots. Strings are immutable: echo/length do not process
or copy every UTF-16 unit, and are not text bandwidth measurements. Bytes test
Uint8Array, Buffer and offset subarrays at 32/1,024/65,536 bytes.

Dart JavaScript uses the same scalar/byte business code with an `-O2` interop
entry, JS checks and explicit copies; its Future scheduling differs. Its error
mapping is omitted. Wasm retains Dart diagnostics that the JS reference omits;
reference error timings do not model hostile diagnostic accessors.

Spread is `(max - min) / median * 100`, not a confidence interval. Short samples
can vary widely. Retain raw samples, increase counts and repeat on the same
machine before claiming a regression or improvement. Build/import and old
first-call scopes must be compared separately.
