# Roadmap

## 0.1.0 — released: native Wasm imports

- [#29: Resolve exports and generate TypeScript declarations](https://github.com/medz/napi/issues/29).
- [#30: Generate native Wasm exports and automatic host interop](https://github.com/medz/napi/issues/30).
- [#33: Make native Wasm ESM named imports the consumer API](https://github.com/medz/napi/issues/33).
- [#31: Package, validate, and publish the first version](https://github.com/medz/napi/issues/31).

Acceptance is defined in the issues and [requirements](requirements.md). This release establishes the complete Dart-to-Wasm-import workflow for synchronous functions on Node.

## 0.2.0 — released: async functions and measured costs

- [#26: Future<T> → Promise<T>](https://github.com/medz/napi/issues/26).
- [#35: Establish reproducible performance and package-size baselines](https://github.com/medz/napi/issues/35); optimize measured bottlenecks.

Acceptance includes native Wasm functions returning real Promises, strict declarations, consistent errors, call-time byte snapshots, and the [0.2.0 requirements](requirements.md#020-contract).

## 0.3.0 — released: typed collections

- [#34: Add typed List and Map exports](https://github.com/medz/napi/issues/34).

Acceptance covers flat scalar collections, nullable containers and values,
Future completion types, strict own-data property validation, independent
ownership, precise declarations, real Node consumers, and measured conversion
and package-size costs. See the [0.3.0 requirements](requirements.md#030-contract).

## 0.4.0 — verified runtime consumers

- [#28: Broader tested compiler/runtime support](https://github.com/medz/napi/issues/28).

Acceptance covers the scalar, Future and collection workflows on Node 22.19.0,
24.5.0, 24.21.0 and 26.11.1, accurate declarations, one compilation per fixture,
and a real esbuild Node application bundle with external Wasm. The browser
instance-phase probe remains a documented limitation. See [tested platforms](platforms.md).

## Next — compiler compatibility and real applications

- Validate new stable Dart SDK releases before expanding the tested compiler table; preserve clear diagnostics for unsupported helper layouts.
- Improve diagnostics and add complete application examples based on real usage.
- Revisit browser native instance imports when runtime support changes. Wasm bundler transformations are a separate route and require real execution evidence.

Each addition starts with concrete Dart and JavaScript code, explicit value/error/ownership rules, and an acceptance case. Release complete, tested workflows in small increments. Dates and platform support are announced only when verified.

## Separate proposals

[#27: Independent Node-API host compatibility](https://github.com/medz/napi/issues/27) is a separate ABI proposal, not a requirement for native Wasm ESM imports. Classes, JavaScript callbacks, and zero-copy buffers need demand and ownership contracts before scheduling. Native `.node` addons are outside the project goal.
