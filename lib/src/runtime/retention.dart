/// A future resource/callback engine lends an operation a reachability lease.
///
/// Acquiring a lease keeps its owner usable until release. Release is idempotent.
/// This interface defines the boundary only: it does not implement disposal,
/// cancellation, shared memory, callbacks, or resource ownership.
abstract interface class OperationLease {
  bool get isReleased;
  void release();
}

abstract interface class OperationOwner {
  OperationLease retainOperation();
}
