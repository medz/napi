import '../ir/model.dart';

final _futureDeclaration = DeclarationId(
  Uri.parse('dart:async'),
  'Future',
  kind: DeclarationKind.classType,
);

/// Completion is a call contract, not a value conversion. Aliases retain the
/// underlying declaration, and returning a Future does not require `async`.
bool isFutureType(BindingType? type) =>
    type is DeclaredType && type.declaration == _futureDeclaration;

/// The value delivered by a validated call, with void represented by null.
BindingType? resultPayload(BindingType? type) {
  if (isFutureType(type)) {
    type = (type! as DeclaredType).typeArguments.single;
  }
  return type is VoidType ? null : type;
}
