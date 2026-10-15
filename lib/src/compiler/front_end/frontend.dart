import '../ir/model.dart';

/// Analyzer-backed discovery and external declarations meet at this boundary.
///
/// Implementations resolve source types before returning semantic IR. They must
/// not embed analyzer elements or infer Dart int semantics from a JS platform's
/// analyzer view. The foundation accepts handwritten IR; discovery is #116.
abstract interface class BindingFrontend {
  Future<BindingModule> read(Uri library);
}
