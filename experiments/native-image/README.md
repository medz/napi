# Native image experiment

Build a single Node-API addon using Dart and the official Dart SDK, without a
C/C++ compiler, assembler, native linker, or signing command.

```sh
dart experiments/native-image/build.dart
node --test experiments/native-image/test.cjs
```

```js
const addon = require('./experiments/native-image/build/addon.node');
console.log(addon.add(20, 22)); // 42
addon.readFile('./config.txt').then(console.log);
addon.isolateRun(21).then(console.log); // 42
addon.httpRoundtrip('hello').then(console.log); // Dart HTTP: hello
```

The functions execute Dart AOT code. `add` accepts JavaScript safe integers and
throws a `TypeError` for invalid arguments or a result outside that range. Each
Node environment, including Workers, owns a Dart isolate; its cleanup hook
stops that environment's child isolates, closes the Dart callbacks, and shuts
down its root isolate. Other Node environments remain usable.

File reads and writes, HTTP, subprocesses, timers, and spawned Dart isolates use
the SDK's native implementations. No `IOOverrides` or Node I/O proxy is used.
Futures return JavaScript Promises. A Node thread-safe function wakes the owning
thread to process Dart messages and microtasks; live Dart ports and outstanding
operations keep Node running until the work finishes. Child Dart isolates run
on the VM's own threads.

The official AOT compiler emits the payload as Mach-O. The Dart builder converts
the SDK's `dartaotruntime` executable into a loadable bundle, embeds the payload,
and generates the ARM64 module entry and VM startup instructions. The SDK's own
`dartaotruntime.sym` supplies internal embedder entry points for standard-library
initialization. The builder preserves runtime imports and relocation metadata
and writes an ad-hoc signature. Node-API calls use `@Native`; exported Dart
functions use `NativeCallable`.

Only `build/addon.node` is needed at runtime; it can be copied by itself to
another directory on the same platform.

This prototype targets macOS arm64 and Dart 3.13.5, revision
`04bcd1036cdc799ac6564988f159ee454d42c822`. It was tested with Node 24.19.0 and
26.11.1. The builder checks the runtime and symbol-table hashes and depends on
that SDK's executable layout and private embedding APIs. This packaging is
experimental. No SDK source tree or prebuilt custom runtime is used.

This is separate from the package's binding generator. It does not implement
other OS/CPU targets or native-asset packaging. Loading different addons with
separate embedded Dart runtimes in one process remains unverified. The VM and
I/O services live for the process lifetime; environment cleanup shuts down the
corresponding isolate group. Dart shares Node's process ID and working directory.

This directory is excluded from the published Dart package.
