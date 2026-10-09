# Request summaries in Dart and Node

Read newline-delimited JSON from stdin, aggregate requests in Dart Wasm and print
one JSON array. The Node program imports `summarize` directly from the generated
Wasm file; all grouping, counting, summing and sorting runs in Dart.

Run these commands from the repository root with Dart 3.13.5 and a
[supported Node version](../../doc/platforms.md):

```sh
dart pub get
dart run napi:build example/requests/summary.dart --name @napi/requests --out example/requests/dist
node example/requests/main.mjs < example/requests/input.ndjson
```

The five input rows produce these summaries, in this order:

| operation | calls | failed | totalDurationUs |
| --- | ---: | ---: | ---: |
| GET /articles | 2 | 1 | 1000 |
| GET /status | 1 | 0 | 50 |
| POST /login | 2 | 1 | 1600 |

Both successful and failed requests contribute their duration. Operation names
remain exact strings: empty strings, whitespace, case and Unicode are preserved.
Results sort by Dart `String.compareTo`, which uses UTF-16 code units. JSON
property order is not part of the application contract.

Each observation requires `operation: string`, `durationUs: number` and
`success: boolean`. Durations must be nonnegative safe integers. Each operation's
total must also stay within `0..9007199254740991`; the Dart code checks before
adding. Different operations have independent totals. The Wasm boundary rejects
wrong or missing fields, fractional/unsafe integers and unsupported containers.

Blank lines and CRLF input are accepted. Empty input prints `[]`. All rows are
parsed before the one Wasm call; malformed JSON, invalid fields or domain errors
set exit code 1, print a readable error to stderr and produce no summary on
stdout. Native import failures are reported by Node before the application runs.
Node may also print its experimental Wasm import warning to stderr on success.

JSON is the command-line input/output format. The Wasm function receives typed
objects and returns typed objects; there is no JSON-string bridge or manual
initialization. Inputs are snapshotted and outputs are independent arrays of
null-prototype objects. The command holds the whole input batch in memory and
pays the normal validation/copy costs; this example makes no performance claim.

The generated package exports `Observation` and `Summary` as TypeScript types,
with `summarize(observations: readonly Observation[]): Summary[]`. Mutable,
readonly, frozen and `as const` input arrays are accepted; result arrays and
summary fields stay mutable. The shipped consumer demonstrates `as const`
input. Check its relative Wasm import with TypeScript 7.0.2:

```sh
npx --yes --package typescript@7.0.2 tsc --strict --noEmit --target ES2022 --module NodeNext --moduleResolution NodeNext --allowArbitraryExtensions example/requests/consumer.mts
```

For an npm consumer, pack/install `example/requests/dist` and import
`summarize` from `@napi/requests` or `@napi/requests/module.wasm`. Both entries point
to the Wasm file; npm type resolution needs no `allowArbitraryExtensions` flag.
Keep the generated host helper beside the Wasm file. See the main
[TypeScript documentation](../../README.md#typescript).
