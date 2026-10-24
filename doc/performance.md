# Backend costs

Wasm keeps the download small and avoids the native bridge for scalar calls.
Native includes a Dart runtime and uses bulk memory transfers for binary data.
Choose using your own workload: package size, startup and byte transfer have
different costs.

## Run the comparison

From a checkout, install the pinned Dart SDK, Node, npm and a Rust toolchain
with the platform's native linker. Then run:

```sh
dart pub get
npm ci --prefix tool/benchmark/rust --ignore-scripts
dart run tool/benchmark.dart /tmp/napi-benchmark /path/to/node24 /path/to/node26
```

The output directory must be new. Omitting Node paths uses `node` from PATH.
The command builds the same small API in Dart native, Dart Wasm and Rust,
packs each npm package and installs its tarball into a separate consumer.
`results.json` contains package sizes, runtime versions and individual samples.
Rust dependencies are locked; its release build enables LTO and symbol stripping.
Dart native builds obtain the pinned precompiled runtime automatically.

The API contains integer addition, a mutable Counter and three byte operations:

| Operation | Dart | napi-rs |
| --- | --- | --- |
| `copyBytes(bytes)` | Uint8List input snapshot; independent output copy | Clone input into a Vec; return externally owned storage |
| `sharedBytes(bytes)` | Checked SharedBytes view; return the original JS object | Borrow the existing Uint8Array; return the original JS object |
| `allocate(size)` | Allocate zeroed host-owned SharedBytes | Return a zeroed Rust Vec as externally owned Uint8Array |

Both byte operations toggle the first byte. Copying leaves the input unchanged;
shared access changes it in place. Allocation reads only the first output byte,
so it does not measure the cost of touching every memory page. Externally owned
Rust storage and host-owned Dart storage have different lifetime and allocation
costs; neither comparison implies the same implementation. See napi-rs's
[typed-array ownership](https://napi.rs/docs/concepts/typed-array).

## Example measurements

Measured on 2026-10-24 with Apple M3 Max arm64, macOS 27.0.1, Dart 3.13.5,
Rust 1.99.1, napi-rs 3.15.0 and napi-rs CLI 3.10.9. Dart bindings were built from
`e73bf87e68b9d1358435b581b963c5fb474ab48c`. Sizes include the generated loaders,
types, licenses and the runtime payload; the installed Node executable is not
part of these packages. Each native package contains only this host's target.

| Complete npm package | Compressed download | Installed files |
| --- | ---: | ---: |
| Dart Wasm | 51.8 KiB | 162.4 KiB |
| Dart native | 2.19 MiB | 6.38 MiB |
| napi-rs | 185.7 KiB | 416.5 KiB |

Each runtime uses three fresh processes per backend, rotating backend order.
All packages load through ESM import, including the napi-rs CommonJS package.
Steady-state values are medians of five timed batches per process after warmup.
Calls use valid small integers: Dart's safe-integer validation and Rust's i32
conversion have different behavior outside this input range.

| Node | Backend | Import median | Added RSS after import | `add` | Counter method |
| --- | --- | ---: | ---: | ---: | ---: |
| 24.19.0 | Dart Wasm | 5.31 ms | 6.48 MiB | 67.7 ns | 19.1 ns |
| 24.19.0 | Dart native | 6.37 ms | 7.06 MiB | 938.8 ns | 813.5 ns |
| 24.19.0 | napi-rs | 2.16 ms | 2.50 MiB | 108.3 ns | 222.8 ns |
| 26.11.1 | Dart Wasm | 4.59 ms | 2.33 MiB | 62.5 ns | 18.9 ns |
| 26.11.1 | Dart native | 8.26 ms | 2.41 MiB | 930.0 ns | 789.7 ns |
| 26.11.1 | napi-rs | 3.14 ms | 1.03 MiB | 104.6 ns | 213.8 ns |

Filesystem caches and machine load were uncontrolled. First imports on Node 24
took 957 ms for Dart native and 296 ms for napi-rs; later imports were much
shorter. The medians above are not a cold-disk startup prediction. RSS is a
process-level observation after V8 GC, not peak memory or a forced Dart GC.

Byte-operation medians on Node 26.11.1, in microseconds per call:

| Backend | Copy 64 B | Copy 4 KiB | Copy 1 MiB | Shared 1 MiB | Allocate 1 MiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| Dart Wasm | 5.05 | 6.05 | 433.88 | 1.03 | 9.67 |
| Dart native | 1.75 | 2.39 | 185.13 | 4.42 | 12.79 |
| napi-rs | 0.54 | 0.95 | 67.44 | 0.15 | 7.95 |

Shared access touches one byte regardless of view length; it does not process
1 MiB. These results describe this API and host, not a general performance
ranking. For application tuning, compare the operations and ownership model
you actually need, including larger batches that reduce boundary crossings.
