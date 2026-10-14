/// Stable identity independent of an analyzer session or element object.
final class DeclarationId {
  final Uri library;
  final String name;
  const DeclarationId(this.library, this.name);

  @override
  bool operator ==(Object other) =>
      other is DeclarationId && library == other.library && name == other.name;
  @override
  int get hashCode => Object.hash(library, name);
}

/// Location in the original input, rather than generated code.
final class SourceLocation {
  final Uri uri;
  final int offset;
  final int length;
  const SourceLocation(this.uri, this.offset, this.length);
  @override
  String toString() => '$uri:$offset';
}

/// The value category survives until an explicit conversion policy is chosen.
enum ValueSemantics { scalar, structural, opaque, reference, shared }

/// A semantic type, with no compiler SDK or analyzer objects attached.
sealed class BindingType {
  const BindingType();
  ValueSemantics get semantics;
}

/// Dart int represented by a JavaScript safe integer, in both directions.
final class SafeIntType extends BindingType {
  const SafeIntType();
  @override
  ValueSemantics get semantics => ValueSemantics.scalar;
}

/// Extension point for future independently implemented conversion engines.
///
/// Merely describing a type does not make it supported by the backend.
final class DeclaredType extends BindingType {
  final DeclarationId declaration;
  @override
  final ValueSemantics semantics;
  const DeclaredType(this.declaration, this.semantics);
}

enum ParameterPresence { required, optional, opaqueRequired, opaqueOptional }

final class ParameterBinding {
  final String name;
  final BindingType type;
  final ParameterPresence presence;
  const ParameterBinding(
    this.name,
    this.type, {
    this.presence = ParameterPresence.required,
  });
}

final class FunctionBinding {
  final DeclarationId declaration;
  final String exportName;
  final SourceLocation source;
  final List<ParameterBinding> parameters;
  final BindingType result;
  FunctionBinding({
    required this.declaration,
    required this.exportName,
    required this.source,
    required Iterable<ParameterBinding> parameters,
    required this.result,
  }) : parameters = List.unmodifiable(parameters);
}

final class BindingModule {
  final Uri source;
  final List<FunctionBinding> functions;
  BindingModule({
    required this.source,
    required Iterable<FunctionBinding> functions,
  }) : functions = List.unmodifiable(functions);
}
