# Performance measurements

Run from the repository root with Dart 3.13.5 or later, Node
`^22.19.0 || >=24.5.0`, and npm:

```sh
dart run benchmark/run.dart --out benchmark/results.json
```

Defaults: one build per fixture, three runtime/import samples, 20,000 small sync
calls, and 2,000 warmup calls.

For focused investigations, `--group records` builds only `minimal` and
`records` and measures 24 record/byte cases. `--group batch` also builds `batch`
and measures 37 cases, including single-record loop controls. Both groups skip
unrelated fixtures and Dart JavaScript compilation. Default `--group all`
retains the full 116-case suite.

```sh
dart run benchmark/run.dart --group records --runs 7 --out benchmark/results.json
dart run benchmark/run.dart --group batch --iterations 2000 --warmup 500 --runs 5 --out benchmark/results.json
```

Each selected fixture still receives a fresh-process native import and cold
smoke call: `answer()` for focused groups, or `add(1.5, 2.5)` for the full suite's
`api` fixture. This first call does not measure record conversion.

The recorded **0.3.0** full-suite run used five samples:

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

## Named record conversion (0.5.0)

The runner also builds a `records` fixture with 1/4/16-field echoes and their
Future equivalents. [`benchmark/records-baseline.json`](../benchmark/records-baseline.json)
retains the corresponding rows and the scalar-only size check from a five-sample
0.5.0 run. Reproduce the full report with:

```sh
dart run benchmark/run.dart --node /path/to/node-22.19.0 --runs 5 --out benchmark/results.json
```

Environment: Dart 3.13.5, Node 22.19.0 / V8 12.4.254.21-node.29, npm 11.12.1,
Apple M3 Max arm64, macOS 27.0.1. Each sync sample has 20,000 calls after 2,000
warmups; each sequential Future sample has 2,000 calls after 200 warmups.
Both implementations validate fixed own-data descriptors and return independent
null-prototype objects. The 1-field input is an int; 4/16 fields mix bool, safe
int, UTF-16 String, and double. Timing includes conversion, allocation and result
consumption; the JavaScript reference covers these valid current-realm inputs,
not the complete cross-realm/Proxy/error contract. No Dart-JS record comparison
is implemented.

| Case | Wasm µs/call | JavaScript µs/call | Wasm spread % |
| --- | ---: | ---: | ---: |
| 1 field | 0.338 | 0.163 | 26.6 |
| 4 fields | 1.221 | 0.562 | 8.5 |
| 16 fields | 4.757 | 2.205 | 1.3 |
| Future, 1 field | 1.277 | 0.452 | 62.1 |
| Future, 4 fields | 2.165 | 0.951 | 11.5 |
| Future, 16 fields | 5.811 | 2.516 | 4.8 |

Wasm makes a temporary JS descriptor snapshot, a typed Dart record and a JS
output object. Field names are cached once per structural shape. The
`ownership_copies: 2` metadata counts input/output boundaries, not physical
allocations. Nullable records and typedef aliases do not add runtime type
constructors. Costs grow with the declared field count and string conversion;
these trivial echoes are slower than the measured JavaScript reference.

The seven-function record fixture has 45,826 Wasm bytes, 28,944 host bytes,
845 bytes per declaration and a 22,627-byte npm archive. Its one observed build
took 2,655.9 ms; native import median was 2.853 ms (2.831–2.942 ms).
The scalar-only fixture remains 17,295 Wasm / 16,703 host bytes and emits no
collection or record helpers. Fixture sizes include different exported functions
and cannot isolate the cost of a single DTO. Short sample spreads remain large;
no speed improvement or general application benefit is claimed.

## Record batches (0.6.0)

[`benchmark/batch-baseline.json`](../benchmark/batch-baseline.json) retains all
batch samples and the scalar-only footprint from a five-sample 0.6.0 run. The
command and environment match the Node 22.19.0 record run above. Sync counts are
20,000 at 0/1/16 rows, 5,000 at 256 and 312 at 4,096; sequential Future counts
are 2,000 / 2,000 / 2,000 / 500 / 50. Warmups scale by the same rule.

Each input has four fields (bool, safe int, UTF-16 String and double). Echo
copies data; normalization trims names in Dart; aggregation sums ids. Batch
calls validate every own Array index and record field. Single-record loops make
one native call per row and skip outer Array validation; the comparison
therefore includes different outer-container work. The JS reference covers
these valid current-realm inputs, not the complete cross-realm/Proxy/error
contract. It can fuse its record input copy with output construction;
`ownership_copies` describes semantic boundaries, not equal physical allocation
counts. Timing consumes length and the first id in O(1), excluding application
traversal of all output records.

Selected medians in **microseconds per completed batch or loop**:

| Operation / rows | Wasm batch | Wasm single-record loop | JS batch | Wasm batch spread % |
| --- | ---: | ---: | ---: | ---: |
| echo / 16 | 26.392 | 19.437 | 9.255 | 2.2 |
| echo / 4,096 | 7078.616 | 4961.949 | 2382.505 | 3.3 |
| normalize / 16 | 27.075 | 20.813 | 9.619 | 4.1 |
| normalize / 4,096 | 7309.812 | 5481.210 | 2428.192 | 2.6 |
| sum / 16 | 16.106 | 12.122 | 2.608 | 7.3 |
| sum / 4,096 | 4102.816 | 3176.386 | 632.585 | 2.4 |

For 16-row echoes, one-field and sixteen-field Wasm batches took
14.422 and 101.317 µs respectively.
The four-field sequential Future echo at 4,096 rows took
7136.788 µs. Zero-row echo took
0.077 µs; short samples have substantial relative variation.

These small transforms and aggregation are slower than the measured single-record
loops and JavaScript. Batching reduces exported calls, but Array snapshots and
per-record descriptors, field conversions and allocations still cost work.
Do not assume batching improves latency; measure useful Dart work in the actual
application. This baseline claims no optimization or application speedup.

The nine-function batch fixture has 47,589 Wasm bytes,
29,877 host bytes, 979 bytes per declaration and a
23,719-byte npm archive. Its one observed build took
2,728.3 ms; native import median was
3.246 ms (3.005–3.843 ms).
The cold first call measures `answer()`, not DTO conversion. The scalar-only
fixture remains 17,295 Wasm / 16,703 host bytes with no collection or record
helpers. Fixtures export different functions, so their sizes cannot isolate
one record or one List layer.

## Record conversion optimization (0.7.0)

[`benchmark/conversion-baseline.json`](../benchmark/conversion-baseline.json)
retains eight raw reports, artifact hashes, build observations and the comparison
method. Before artifacts use commit `08337d2962bc550bae95cbad123676119b353aa8`
(0.6.0); after artifacts use the recorded candidate bridge hash. Both were
compiled once with Dart 3.13.5 and reused with the same measurement script on
Node 22.19.0 / V8 12.4.254.21-node.29, Apple M3 Max, macOS 27.0.1, npm 11.12.1.
Paired artifact manifests still contain generator version 0.6.0; only the bridge
changes. Declarations and npm metadata are byte-identical between phases.

The bridge passes each static field suffix separately and composes its full
diagnostic path on conversion failure. Successful calls retain per-record and
list-index contexts, descriptor validation and ownership copies. The compiler
already folds constant paths for direct record calls; this change does not
remove every conversion allocation.

The first round runs before then after; the second reverses that order. Record
sync cases use 20,000 calls and 2,000 warmups; Future cases use 2,000 and 200,
with seven samples each. Batch base sync counts are 2,000 calls and 500 warmups;
Future base counts are 200 and 50, with five samples each. Large inputs use the
scaled counts retained in each row. Native artifacts are imported directly,
with no concurrent heavy work. JS controls, inputs, counts, preflight and result
consumption are identical between phases. To reproduce, build the same benchmark fixtures in the base
and candidate checkouts, then run the recorded `benchmark/measure.mjs` command
against both artifact file URIs in both orders.

Selected medians in **microseconds per completed batch or loop**:

| Case / round | Before Wasm | After Wasm | Change | Before JS | After JS |
| --- | ---: | ---: | ---: | ---: | ---: |
| normalize / 256 / forward | 421.724 | 409.832 | −2.82% | 145.310 | 145.167 |
| normalize / 256 / reverse | 421.478 | 409.702 | −2.79% | 147.793 | 148.515 |
| single-record normalize loop / 256 / forward | 323.707 | 310.068 | −4.21% | 135.905 | 136.122 |
| single-record normalize loop / 256 / reverse | 326.245 | 309.256 | −5.21% | 137.798 | 138.604 |

Those four Wasm sample ranges do not overlap their corresponding before ranges;
the JSON retains every minimum, maximum and spread. Across 37 batch cases,
29 improve in both rounds, five regress nominally in both and three change
direction. Most ranges overlap. Four of the five nominal regressions are empty
batches, which do no field conversion; the remaining one-row Future echo also
has overlapping ranges. All six direct-record ranges overlap in the reverse
round, so there is **no stable direct-record speedup claim**. These are modest
batch improvements in one environment, not application performance guarantees.

The unchanged record fixture shrinks from 45,826 to 45,416 Wasm bytes and from
28,950 to 27,840 host bytes: 1,520 bytes combined. Its generated host has changed
compiler string constants, with no new host API. The batch fixture shrinks from
47,589 to 47,546 Wasm bytes; host size remains 29,877 bytes. Each declaration
remains 845 and 979 bytes respectively. The scalar-only fixture remains
17,295 Wasm / 16,703 host bytes, with no collection or record helpers.
Packing those same five-file artifacts gives record archives of 22,638 → 22,507
bytes and batch archives of 23,719 → 23,781 bytes. Compressed batch size increases
by 62 bytes despite the smaller raw Wasm; archive contents were checked against
all compiled files. Single build observations do not establish build-time
improvements. This paired run makes no cold-import improvement claim.

## Byte fields in records (0.10.0)

[`benchmark/record-bytes-baseline.json`](../benchmark/record-bytes-baseline.json)
retains source hashes, seven raw samples per case, scaled counts and artifact
costs. This contemporaneous comparison uses Dart 3.13.5, Node 22.19.0 /
V8 12.4.254.21-node.29, npm 11.12.1, Apple M3 Max and macOS 27.0.1:

```sh
dart run benchmark/run.dart --group records --iterations 20000 --warmup 2000 --runs 7 --out benchmark/record-bytes-baseline.json
```

The existing record fixture adds `echoPacket` and `echoPacketPayload` for
metadata-plus-bytes and top-level bytes. Eighteen paired cases use the same
32/1,024/65,536-byte Uint8Array, Buffer or offset subarray, with identical counts
and warmups. Both routes include two explicit ownership copies. The record adds
two own-field checks, a five-code-unit name and record allocations. The JS
references perform actual copies and validate only the measured valid shapes;
they do not implement the complete cross-realm/Proxy/error contract. Preflight
checks visible contents and independent result storage; the runtime acceptance
suite separately verifies owned business inputs and Future snapshots.

Selected Uint8Array medians in **microseconds per synchronous call**:

| Bytes | Calls / sample | Wasm record | Wasm bytes | JS record | Wasm record spread % |
| --- | ---: | ---: | ---: | ---: | ---: |
| 32 | 20,000 | 0.786 | 0.260 | 0.313 | 4.8 |
| 1,024 | 1,250 | 0.971 | 0.526 | 0.547 | 13.5 |
| 65,536 | 50 | 3.854 | 2.500 | 2.789 | 146.4 |

The 65,536-byte samples are short and vary widely; they do not establish a
stable relative cost. This run measures conversion costs, with no before/after
speedup claim. Packet result consumption also reads payload contents and the
name, so historical record timings are not a direct optimization comparison.

The nine-function record fixture has 47,417 Wasm bytes, 30,256 host bytes,
1,054 bytes per declaration and a 23,959-byte npm archive. It emits the optional
`copyRecordBytes` helper. The scalar-only fixture remains 17,295 Wasm / 16,703
host bytes with no collection or byte-field helper. Fixtures export different
functions, so these totals do not isolate one field's size. The complete run
took 7.783 seconds; each fixture was built once, with no build-time improvement
claim or correctness timing gate.

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

## File CRC32 word reads (unreleased)

The existing file-checksum example now uses slicing-by-four over a `ByteData`
view of its already-owned input. It reads a little-endian word for each complete
four-byte block; a byte loop handles the tail. The view is skipped for inputs
shorter than four bytes and does not copy the payload. Four 256-entry tables
replace one, adding 3 KiB of persistent table storage after first use.

[`benchmark/checksum-word-baseline.json`](../benchmark/checksum-word-baseline.json)
contains source/driver/artifact hashes and all 14 interleaved pairs per size,
seven in each order. Both phases use the same inputs, counts, warmups, result
consumption and explicit GC outside timed batches. Native calls include input
ownership conversion and result construction; preflight compares CRCs with
Node's built-in function and verifies unchanged bytes. The baseline is the
previously verified 0.12.0 artifact, not rebuilt. The final measured source is
byte-identical to the updated example. Dart 3.13.5, Node 26.11.1 /
V8 14.6.202.34-node.37, Apple M3 Max and macOS 27.0.1 were used.

Median **microseconds per synchronous call** in this run:

| Bytes | Calls / sample | Byte loop | Word loop |
| --- | ---: | ---: | ---: |
| 0 | 5,000 | 0.744 | 0.759 |
| 32 | 5,000 | 0.944 | 0.920 |
| 1,024 | 1,000 | 6.152 | 2.887 |
| 65,536 | 100 | 340.105 | 129.112 |
| 1,048,576 | 20 | 5,389.396 | 2,076.151 |

The 1 KiB–1 MiB cases are about 2.1–2.6 times as fast in this comparison and
improve in both orders. The few-percent differences at 0/32 bytes do not
establish a small-input speedup. This measures warm calls on one host and SDK;
it does not measure module startup, file I/O, CLI latency or a speed advantage
over Node's built-in CRC32. No timing threshold is enforced in CI.

The measured packages contain 27,860 / 29,766 Wasm bytes and 24,665 / 25,822 host
bytes before / after: 3,063 additional bytes combined. Both declarations remain
identical at 215 bytes.
The earlier unguarded-word prototype and the rejected extra-copy experiment are
excluded from these figures. Each distinct candidate was compiled once; the
two word candidates reused the baseline and their compiled artifacts throughout.

To compare two already-built packages without rebuilding or packing them:

```sh
node --expose-gc benchmark/checksum.mjs before/module.wasm after/module.wasm > checksum-comparison.json
```

Build both phases with the same SDK. The before source is
`example/checksum/checksum.dart` at `v0.12.0`; the after source is the current
example. The command checks native function identity and declaration equality,
uses Node CRC32 as a correctness reference, and emits raw samples and hashes.

## Host record snapshots (unreleased)

[`benchmark/record-snapshot-baseline.json`](../benchmark/record-snapshot-baseline.json)
retains two fresh-process, same-process A/B rounds on Node 26.11.1
(V8 14.6.202.34-node.37), Apple M3 Max, arm64, macOS 27.0.0. Both use the
Dart 3.13.5 CI fixtures from `e06a091529ea3c1e271e5ed5fec9377198d0f637`.
Only the generated `snapshotRecord` host body changes; the Wasm, both
declarations and package manifests are byte-identical. No Dart compilation or
tool download was needed for this experiment.

The helper keeps ordinary-object validation and ordered own-data-descriptor
reads, but lets `Array.from` create the snapshot slots instead of constructing
a descriptor object and calling `Object.defineProperty` for each slot.
Its null-prototype array-like input avoids inherited iterators and indexed
getters. The [Array.from algorithm](https://tc39.es/ecma262/multipage/indexed-collections.html#sec-array.from)
creates own data properties; focused regression checks cover inherited numeric
setters, Array species and the resulting slot descriptors.

The same three-field `User` records exercise dictionary, list and per-row native
echo/normalize calls. Sizes are 0/1/16/256, with 20,000/20,000/4,096/256 calls
per sample and 2,000/2,000/409/100 warmups. Each round retains five samples and
rotates implementation order; the second process reverses the base order.
Known-field consumption is timed, while value and ownership assertions run
outside timing. JIT, GC and system load are uncontrolled.

Forward-round medians for 256 rows, in microseconds per call:

| Route / operation | Before | After | Change | Reverse change |
| --- | ---: | ---: | ---: | ---: |
| Dictionary echo | 378.352 | 347.356 | −8.19% | −8.52% |
| Dictionary normalize | 398.981 | 360.717 | −9.59% | −7.07% |
| List echo | 287.564 | 258.984 | −9.94% | −9.27% |
| List normalize | 298.642 | 266.483 | −10.77% | −9.96% |
| Per-row echo loop | 212.151 | 186.813 | −11.94% | −12.64% |
| Per-row normalize loop | 218.470 | 193.726 | −11.33% | −13.45% |

These results measure conversion-heavy small transforms, not application speed.
Dictionary conversion still costs more than list conversion here, and the
per-row loop remains faster than either bulk route; it lacks outer-container
validation and creates an Array. Use dictionaries for keyed data rather than
assuming batching improves a trivial transform. Empty-input samples are under
3ms and noisy; they support no speed claim. JavaScript controls cover only
valid current-realm descriptor/scalar checks and fresh output objects, without
the complete Proxy/error/cross-realm contract or Dart-owned business input.

The `record-maps`, `batch` and `records` host files each shrink by 146 bytes
(35,450 → 35,304; 33,866 → 33,720; 33,159 → 33,013). Their other four artifacts
remain unchanged. Helpers are still emitted only when used.

To compare already-built fixture directories containing
`{record-maps,batch,records}/dist`, reuse their artifacts:

```sh
node benchmark/record-snapshot.mjs after-fixtures forward.json forward before-fixtures
node benchmark/record-snapshot.mjs after-fixtures reverse.json reverse before-fixtures
```

[`benchmark/record-snapshot.mjs`](../benchmark/record-snapshot.mjs) checks values,
output independence and null-prototype records, records asset and driver hashes,
and writes every sample. Omit the last argument for a single-artifact
Map/List/per-row baseline. Native export identity, invalid input, byte ownership
and async error behavior are covered separately by runtime acceptance.
