/// Stable identity independent of an analyzer session or element object.
///
/// A member's owner and declaration kind distinguish, for example, a field,
/// getter and setter with the same spelling in two different classes.
enum DeclarationKind {
  function,
  classType,
  enumType,
  mixinType,
  extensionType,
  constructor,
  method,
  getter,
  setter,
  field,
  typeParameter,
  typedefType,
}

final class DeclarationId {
  final Uri library;
  final String name;
  final DeclarationId? owner;
  final DeclarationKind kind;

  /// Positional identity for wildcard type parameters with no usable name.
  final int? slot;
  const DeclarationId(
    this.library,
    this.name, {
    this.owner,
    this.kind = DeclarationKind.function,
    this.slot,
  });

  @override
  bool operator ==(Object other) =>
      other is DeclarationId &&
      library == other.library &&
      name == other.name &&
      owner == other.owner &&
      kind == other.kind &&
      slot == other.slot;
  @override
  int get hashCode => Object.hash(library, name, owner, kind, slot);
}

/// Location in the original input, rather than generated code.
///
/// [line] and [column], when present, are one-based. A declaration in a part
/// retains that part's URI, while its identity retains the owning library URI.
final class SourceLocation {
  final Uri uri;
  final int offset;
  final int length;
  final int? line;
  final int? column;
  const SourceLocation(
    this.uri,
    this.offset,
    this.length, {
    this.line,
    this.column,
  });
  @override
  String toString() => line == null ? '$uri:$offset' : '$uri:$line:$column';
}

/// The value category survives until an explicit conversion policy is chosen.
enum ValueSemantics { scalar, structural, opaque, reference, shared }

enum TypeNullability { nonNullable, nullable, legacy }

/// A semantic type, with no compiler SDK or analyzer objects attached.
///
/// Merely describing a type does not make it supported by the backend. Alias
/// metadata records the spelling that introduced the underlying semantic type.
sealed class BindingType {
  final TypeNullability nullability;
  final TypeAliasBinding? alias;
  const BindingType({
    this.nullability = TypeNullability.nonNullable,
    this.alias,
  });
  ValueSemantics get semantics;
}

/// Dart int, using JavaScript safe integers unless [FunctionBinding.bigint]
/// explicitly selects JavaScript bigint conversion for the function.
final class SafeIntType extends BindingType {
  const SafeIntType({super.nullability, super.alias});
  @override
  ValueSemantics get semantics => ValueSemantics.scalar;
}

/// A reference to a declared type with its instantiated type arguments.
final class DeclaredType extends BindingType {
  final DeclarationId declaration;
  final List<BindingType> typeArguments;
  @override
  final ValueSemantics semantics;
  DeclaredType(
    this.declaration,
    this.semantics, {
    Iterable<BindingType> typeArguments = const [],
    super.nullability,
    super.alias,
  }) : typeArguments = List.unmodifiable(typeArguments);
}

final class TypeParameterType extends BindingType {
  final DeclarationId declaration;
  const TypeParameterType(this.declaration, {super.nullability, super.alias});
  @override
  ValueSemantics get semantics => ValueSemantics.opaque;
}

final class DynamicType extends BindingType {
  const DynamicType({super.nullability, super.alias});
  @override
  ValueSemantics get semantics => ValueSemantics.opaque;
}

final class VoidType extends BindingType {
  const VoidType({super.nullability, super.alias});
  @override
  ValueSemantics get semantics => ValueSemantics.scalar;
}

final class NeverType extends BindingType {
  const NeverType({super.nullability, super.alias});
  @override
  ValueSemantics get semantics => ValueSemantics.scalar;
}

final class FunctionTypeBinding extends BindingType {
  final BindingType result;
  final List<ParameterBinding> parameters;
  final List<TypeParameterBinding> typeParameters;
  FunctionTypeBinding({
    required this.result,
    required Iterable<ParameterBinding> parameters,
    Iterable<TypeParameterBinding> typeParameters = const [],
    super.nullability,
    super.alias,
  }) : parameters = List.unmodifiable(parameters),
       typeParameters = List.unmodifiable(typeParameters);
  @override
  ValueSemantics get semantics => ValueSemantics.reference;
}

final class RecordTypeBinding extends BindingType {
  final List<BindingType> positional;
  final Map<String, BindingType> named;
  RecordTypeBinding({
    Iterable<BindingType> positional = const [],
    Map<String, BindingType> named = const {},
    super.nullability,
    super.alias,
  }) : positional = List.unmodifiable(positional),
       named = Map.unmodifiable(named);
  @override
  ValueSemantics get semantics => ValueSemantics.structural;
}

final class TypeAliasBinding {
  final DeclarationId declaration;
  final List<BindingType> typeArguments;
  TypeAliasBinding({
    required this.declaration,
    Iterable<BindingType> typeArguments = const [],
  }) : typeArguments = List.unmodifiable(typeArguments);
}

final class TypeParameterBinding {
  final DeclarationId declaration;
  final SourceLocation? source;
  final BindingType? bound;
  final BindingType? defaultType;
  final String? documentation;
  const TypeParameterBinding({
    required this.declaration,
    this.source,
    this.bound,
    this.defaultType,
    this.documentation,
  });
}

enum ParameterPresence { required, optional, opaqueRequired, opaqueOptional }

enum ParameterKind {
  requiredPositional,
  optionalPositional,
  requiredNamed,
  optionalNamed,
}

final class ParameterBinding {
  final String name;
  final BindingType type;
  final ParameterPresence presence;
  final ParameterKind kind;
  final String? defaultSource;
  final bool hasDefault;
  final SourceLocation? source;
  final String? documentation;
  final bool isInitializingFormal;
  final bool isSuperFormal;
  final bool isCovariant;
  const ParameterBinding(
    this.name,
    this.type, {
    ParameterPresence? presence,
    this.kind = ParameterKind.requiredPositional,
    this.defaultSource,
    bool hasDefault = false,
    this.source,
    this.documentation,
    this.isInitializingFormal = false,
    this.isSuperFormal = false,
    this.isCovariant = false,
  }) : hasDefault = hasDefault || defaultSource != null,
       presence =
           presence ??
           (kind == ParameterKind.optionalPositional ||
                   kind == ParameterKind.optionalNamed
               ? ParameterPresence.optional
               : ParameterPresence.required);
}

final class FunctionBinding {
  final DeclarationId declaration;
  final String exportName;
  final SourceLocation source;
  final List<ParameterBinding> parameters;
  final BindingType result;
  final String? documentation;
  final List<TypeParameterBinding> typeParameters;

  /// Dart expression path relative to an import of [exportSurface].
  final String callPath;

  /// The selected library that exposes this declaration, including re-exports.
  /// This is intentionally separate from [declaration]'s origin library.
  final Uri exportSurface;
  final bool isExternal;
  final bool isAsync;
  final bool isGenerator;

  /// Represent every Dart int parameter and result as JavaScript bigint.
  /// Dart BigInt always uses bigint, independently of this policy.
  final bool bigint;
  FunctionBinding({
    required this.declaration,
    required this.exportName,
    required this.source,
    required Iterable<ParameterBinding> parameters,
    required this.result,
    this.documentation,
    Iterable<TypeParameterBinding> typeParameters = const [],
    String? callPath,
    Uri? exportSurface,
    this.isExternal = false,
    this.isAsync = false,
    this.isGenerator = false,
    this.bigint = false,
  }) : parameters = List.unmodifiable(parameters),
       typeParameters = List.unmodifiable(typeParameters),
       callPath = callPath ?? declaration.name,
       exportSurface = exportSurface ?? declaration.library;
}

enum MemberKind { constructor, method, getter, setter, field }

/// Why a declared member was included in, or omitted from, the export surface.
///
/// Excluded members remain descriptive metadata. Neither implicit nor explicit
/// selection assigns a JavaScript runtime representation to a member.
enum MemberSelection { implicit, explicit, excluded }

final class MemberBinding {
  final DeclarationId declaration;
  final SourceLocation source;
  final MemberKind kind;
  final MemberSelection selection;
  final String? exportName;
  final bool hasExplicitExportName;
  final String? documentation;
  final List<ParameterBinding> parameters;
  final BindingType? result;
  final BindingType? type;
  final List<TypeParameterBinding> typeParameters;
  final String? callPath;
  final String? initializerSource;
  final bool isStatic;
  final bool isFactory;
  final bool isConst;
  final bool isAbstract;
  final bool isExternal;
  final bool isFinal;
  final bool isLate;
  final bool isSynthetic;
  final bool isAsync;
  final bool isGenerator;
  final bool isOperator;
  MemberBinding({
    required this.declaration,
    required this.source,
    required this.kind,
    required this.selection,
    this.exportName,
    this.hasExplicitExportName = false,
    this.documentation,
    Iterable<ParameterBinding> parameters = const [],
    this.result,
    this.type,
    Iterable<TypeParameterBinding> typeParameters = const [],
    this.callPath,
    this.initializerSource,
    this.isStatic = false,
    this.isFactory = false,
    this.isConst = false,
    this.isAbstract = false,
    this.isExternal = false,
    this.isFinal = false,
    this.isLate = false,
    this.isSynthetic = false,
    this.isAsync = false,
    this.isGenerator = false,
    this.isOperator = false,
  }) : parameters = List.unmodifiable(parameters),
       typeParameters = List.unmodifiable(typeParameters);
}

final class ClassBinding {
  final DeclarationId declaration;
  final String exportName;
  final SourceLocation source;
  final String? documentation;
  final List<MemberBinding> members;
  final List<TypeParameterBinding> typeParameters;
  final String callPath;
  final Uri exportSurface;
  final bool isAbstract;
  final bool isSealed;
  final bool isBase;
  final bool isInterface;
  final bool isFinal;
  final bool isMixinClass;
  final BindingType? supertype;
  final List<BindingType> interfaces;
  final List<BindingType> mixins;
  ClassBinding({
    required this.declaration,
    required this.exportName,
    required this.source,
    Iterable<MemberBinding> members = const [],
    Iterable<TypeParameterBinding> typeParameters = const [],
    this.documentation,
    String? callPath,
    Uri? exportSurface,
    this.isAbstract = false,
    this.isSealed = false,
    this.isBase = false,
    this.isInterface = false,
    this.isFinal = false,
    this.isMixinClass = false,
    this.supertype,
    Iterable<BindingType> interfaces = const [],
    Iterable<BindingType> mixins = const [],
  }) : members = List.unmodifiable(members),
       typeParameters = List.unmodifiable(typeParameters),
       callPath = callPath ?? declaration.name,
       exportSurface = exportSurface ?? declaration.library,
       interfaces = List.unmodifiable(interfaces),
       mixins = List.unmodifiable(mixins);
}

/// Declarations exposed through one entry library, with their original identity.
final class BindingModule {
  final Uri source;
  final List<FunctionBinding> functions;
  final List<ClassBinding> classes;
  BindingModule({
    required this.source,
    Iterable<FunctionBinding> functions = const [],
    Iterable<ClassBinding> classes = const [],
  }) : functions = List.unmodifiable(functions),
       classes = List.unmodifiable(classes);
}
