/// Marks a public top-level function as a native WebAssembly ES module export.
///
/// Exported functions must be synchronous and use required positional
/// parameters with supported value types.
const napi = Napi();

/// The annotation type used by [napi].
final class Napi {
  const Napi();
}
