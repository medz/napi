/// Marks a declaration for binding selection by the future export frontend.
///
/// The foundation fixture runner selects functions explicitly; it does not yet
/// interpret annotations. Configuration belongs on this single annotation.
class NAPI {
  const NAPI({this.name});

  final String? name;
}
