/// Analyzer-independent declaration identity, stable across public renames.
final class DeclarationIdentity {
  const DeclarationIdentity({required this.libraryUri, required this.name});

  final Uri libraryUri;
  final String name;

  @override
  bool operator ==(Object other) =>
      other is DeclarationIdentity &&
      libraryUri == other.libraryUri &&
      name == other.name;

  @override
  int get hashCode => Object.hash(libraryUri, name);
}

/// Offsets and lengths are UTF-16 code units; line and column are one-based.
final class SourceSpan {
  const SourceSpan({
    required this.uri,
    required this.offset,
    required this.length,
    required this.line,
    required this.column,
  });

  final Uri uri;
  final int offset;
  final int length;
  final int line;
  final int column;

  @override
  String toString() => '$uri:$line:$column';
}

enum PrimitiveKind { integer, doublePrecision, boolean, string, voidType }

/// Contract policy, not an executable conversion or analyzer type.
///
/// Integers use checked JavaScript safe numbers in both directions. Doubles
/// preserve IEEE-754 special values and negative zero. Strings preserve UTF-16.
final class PrimitiveTypePolicy {
  const PrimitiveTypePolicy(this.kind, {this.nullable = false});

  final PrimitiveKind kind;
  final bool nullable;
}

final class ParameterBinding {
  const ParameterBinding({
    required this.name,
    required this.type,
    required this.source,
  });

  final String name;
  final PrimitiveTypePolicy type;
  final SourceSpan source;
}

final class FunctionBinding {
  FunctionBinding({
    required this.identity,
    required this.source,
    required this.dartName,
    required this.publicName,
    required Iterable<ParameterBinding> parameters,
    required this.returnType,
  }) : parameters = List.unmodifiable(parameters);

  final DeclarationIdentity identity;
  final SourceSpan source;
  final String dartName;
  final String publicName;
  final List<ParameterBinding> parameters;
  final PrimitiveTypePolicy returnType;
}

final class BindingModule {
  BindingModule({
    required this.sourceUri,
    required Iterable<FunctionBinding> functions,
  }) : functions = List.unmodifiable(functions);

  final Uri sourceUri;
  final List<FunctionBinding> functions;
}
