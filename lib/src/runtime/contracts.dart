/// Adapter contracts for subsequent binding engines. These are not engines.
///
/// Hosts are generic so contracts stay independent of JavaScript, the analyzer,
/// and the compiler. Real JS carriers must preserve supplied null and undefined
/// distinctly, before either crosses the nullable Dart interop boundary.
library;

/// Capabilities that must be negotiated before a binding can execute.
enum RuntimeCapability {
  structuralValues,
  opaqueValues,
  boundInstances,
  ownedBytes,
  sharedBytes,
  retainedOperations,
}

/// Explicit failure for capabilities not implemented by this foundation.
Never unsupportedCapability(RuntimeCapability capability) =>
    throw UnsupportedError(
      'Binding capability ${capability.name} is not implemented',
    );

/// Omission is separate from a supplied value, including supplied null.
sealed class ArgumentPresence<T> {
  const ArgumentPresence();
}

final class OmittedArgument<T> extends ArgumentPresence<T> {
  const OmittedArgument();
}

final class SuppliedArgument<T> extends ArgumentPresence<T> {
  const SuppliedArgument(this.value);
  final T value;
}

/// An identity domain belongs to one initialized Wasm module instance.
///
/// Tokens are compared by identity, never serialized or shared across instances.
abstract interface class RuntimeDomain {
  Object get identity;
}

/// Conversion location, distinct from a compiler source span.
final class ValuePath {
  const ValuePath(this.value);
  final String value;
  ValuePath field(String name) => ValuePath('$value.$name');
  ValuePath index(int index) => ValuePath('$value[$index]');
  @override
  String toString() => value;
}

/// A failed adapter conversion. Adapters must not hide it behind a default value.
final class BindingConversionException implements Exception {
  const BindingConversionException(this.path, this.message);
  final ValuePath path;
  final String message;
  @override
  String toString() => '$path: $message';
}

/// A transaction for temporary conversion resources.
///
/// An engine must roll back partial conversion on every failure. Cleanup is
/// idempotent and must not mask the primary error. A successful call closes its
/// scope after output conversion; retained work transfers its holds explicitly.
abstract interface class ConversionScope {
  RuntimeDomain get domain;
  void onCleanup(void Function() cleanup);
  void close();
}

/// Structural snapshots allocate independent containers in both directions.
///
/// Element adapters decide each element's identity policy. A map adapter uses
/// JS Map semantics; an object dictionary is a separate explicit adapter.
abstract interface class StructuralValueAdapter<DartValue, HostValue> {
  DartValue fromHost(HostValue value, ValuePath path, ConversionScope scope);
  HostValue toHost(DartValue value, ValuePath path, ConversionScope scope);
}

/// A carrier preserves an arbitrary host value and its runtime domain.
///
/// It must distinguish JS null from undefined and keep payload identity. It is
/// not permission to instantiate a concrete Dart generic type from host data.
abstract interface class OpaqueCarrier<HostValue> {
  RuntimeDomain get domain;
  HostValue get value;
}

abstract interface class OpaqueValueAdapter<HostValue> {
  OpaqueCarrier<HostValue> retain(
    HostValue value,
    ValuePath path,
    ConversionScope scope,
  );
  HostValue restore(
    OpaqueCarrier<HostValue> carrier,
    ValuePath path,
    RuntimeDomain domain,
  );
}

/// Bound identity must reject foreign-runtime, forged and disposed instances.
///
/// Restoring a live Dart object preserves its live host identity. Implementations
/// must not keep a process-global strong registry of all exported instances.
abstract interface class BoundInstanceAdapter<DartValue, HostValue> {
  DartValue unwrap(HostValue value, ValuePath path, ConversionScope scope);
  HostValue wrap(DartValue value, ValuePath path, ConversionScope scope);
}

enum ByteOwnership { ownedSnapshot, sharedView }

/// Sharing is a capability, never a silent fallback to copying.
abstract interface class ByteAdapter<DartValue, HostValue> {
  bool supports(ByteOwnership ownership);
  DartValue fromHost(
    HostValue value,
    ByteOwnership ownership,
    ValuePath path,
    ConversionScope scope,
  );
  HostValue toHost(
    DartValue value,
    ByteOwnership ownership,
    ValuePath path,
    ConversionScope scope,
  );
}

/// A resource retained for one pending operation. Release must be idempotent.
abstract interface class OperationHold {
  void release();
}

/// Async engines must retain before scheduling and release on every terminal
/// path (success, failure, cancellation), including conversion failures.
///
/// Disposal prevents new holds but does not invalidate an already accepted
/// operation. Callback and stream engines use this same ownership boundary.
abstract interface class OperationRetention {
  OperationHold acquire(ValuePath path);
}
