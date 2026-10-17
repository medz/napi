/// Keeps an accepted operation's owner reachable and usable until release.
///
/// Release is idempotent. Adapters release in `finally`, after their operation's
/// last use, including result conversion or asynchronous settlement. A lease
/// does not cancel work or imply that an owner requires explicit cleanup.
abstract interface class OperationLease {
  bool get isReleased;
  void release();
}

/// Accepts an operation or throws before the operation starts.
///
/// Resource controls reject new operations once disposal starts. Other owners
/// may implement retention without a disposal lifecycle.
abstract interface class OperationOwner {
  OperationLease retainOperation();
}
