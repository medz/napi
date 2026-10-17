/// An explicit, cooperative cancellation request supplied by JavaScript.
///
/// Bindings accept a supported JavaScript AbortSignal for this type. A request
/// does not stop arbitrary Dart work: the operation must observe the signal and
/// complete only after its own shutdown. Tokens remain usable while Dart code
/// retains them, including after the original export has returned.
abstract interface class AbortSignal {
  /// Whether cancellation has been requested, read from the actual host signal.
  bool get aborted;

  /// Throws the original JavaScript abort reason through the binding.
  ///
  /// Dart code can catch and rethrow this private carrier. An uncaught failure
  /// crosses the boundary as the original reason, without cloning or coercion.
  void throwIfAborted();

  /// Registers one notification and returns an idempotent removal function.
  ///
  /// Notifications run asynchronously in the registration's zone, including
  /// registrations made after cancellation. Removing a queued notification
  /// suppresses it. A notification is not confirmation that work has stopped.
  void Function() onAbort(void Function() listener);
}
