import '../ir/binding.dart';

/// Declaration producers normalize source data before analysis and lowering.
///
/// Selection is explicit in the foundation fixture implementation. Annotation
/// and external-binding selection will implement this boundary in #108.
abstract interface class BindingFrontend {
  Future<BindingModule> resolve({
    required String path,
    required Iterable<String> functionNames,
  });
}
