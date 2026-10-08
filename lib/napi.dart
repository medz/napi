/// Marks a public top-level function for export through Wasm Node-API.
///
/// Exported functions must be synchronous and use required positional
/// parameters with supported value types.
const napi = Napi();

/// The annotation type used by [napi].
final class Napi {
  const Napi();
}
