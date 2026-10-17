import '../../api/annotation.dart';
import '../ir/model.dart';

/// Static selections for an existing library, without changing its source.
///
/// Signatures, defaults, documentation and declaration identities are resolved
/// from the library itself. The same [NAPI] configuration is used by source
/// annotations and these build-script selections.
final class ExternalLibrary {
  final List<ExternalDeclaration> declarations;
  const ExternalLibrary(this.declarations);
}

sealed class ExternalDeclaration {
  final String name;
  final NAPI config;

  /// Optional location of the selection in the build script.
  ///
  /// Missing selections report this location when supplied; declarations that
  /// resolve retain their original Dart source locations.
  final SourceLocation? source;
  const ExternalDeclaration(this.name, {required this.config, this.source});
}

final class ExternalFunction extends ExternalDeclaration {
  const ExternalFunction(
    super.name, {
    super.config = const NAPI(),
    super.source,
  });
}

/// Select a class or concrete class alias and its own public members.
///
/// Overrides on aliases belong to that selection; another alias of the same
/// original class retains its independently selected member configuration.
///
/// Member selections use declaration kinds so a getter and setter with the
/// same name can be configured independently. Unlisted public members retain
/// implicit selection, just as on an annotated class.
final class ExternalClass extends ExternalDeclaration {
  final List<ExternalMember> members;
  const ExternalClass(
    super.name, {
    super.config = const NAPI(),
    super.source,
    this.members = const [],
  });
}

final class ExternalMember {
  final String name;
  final MemberKind kind;
  final NAPI config;
  final SourceLocation? source;

  /// An unnamed constructor uses the Dart constructor name `new`.
  const ExternalMember.constructor(
    this.name, {
    this.config = const NAPI(),
    this.source,
  }) : kind = MemberKind.constructor;

  const ExternalMember.method(
    this.name, {
    this.config = const NAPI(),
    this.source,
  }) : kind = MemberKind.method;

  const ExternalMember.getter(
    this.name, {
    this.config = const NAPI(),
    this.source,
  }) : kind = MemberKind.getter;

  const ExternalMember.setter(
    this.name, {
    this.config = const NAPI(),
    this.source,
  }) : kind = MemberKind.setter;

  const ExternalMember.field(
    this.name, {
    this.config = const NAPI(),
    this.source,
  }) : kind = MemberKind.field;
}
