import '../../analysis/validate.dart';
import '../../ir/model.dart';
import '../../lowering/plan.dart';
import 'documentation.dart';

/// Public record typedefs describe the default mutable output representation.
/// Calls retain their inline types, including readonly input and bigint policy.
String emitRecordAliases(
  List<ClassBinding> classes,
  List<ValueClassSchema> values,
  Iterable<ValueConversion> conversions, {
  Set<String> reservedNames = const {},
}) {
  final defaults = [
    for (final schema in values)
      conversionFor(
        schema.binding.instantiatedType ??
            DeclaredType(schema.binding.declaration, ValueSemantics.reference),
        schema.binding.exportName,
        bigint: false,
        classes: classes,
        valueSchemas: values,
      ),
  ];
  final records = <DeclarationId, RecordTypeBinding>{};
  final names = <String, DeclarationId>{};
  for (final node in conversionGraph([...conversions, ...defaults])) {
    if (node is! RecordConversion) continue;
    final type = node.type;
    final alias = type.alias;
    // Generic aliases were not exported by 0.14. Their instantiated use-site
    // shapes remain supported inline; private names do not become public API.
    if (alias == null ||
        alias.typeArguments.isNotEmpty ||
        alias.declaration.name.startsWith('_')) {
      continue;
    }
    final name = alias.declaration.name;
    if (!RegExp(r'^[A-Za-z$][A-Za-z0-9_$]*$').hasMatch(name) ||
        name.startsWith(r'$napi') ||
        name.startsWith(r'$value') ||
        _reserved.contains(name)) {
      throw BindingDiagnostic(
        'NAPI_NAME',
        'Unsupported public TypeScript record alias name $name.',
        alias.source,
      );
    }
    final previous = names[name];
    if (reservedNames.contains(name) ||
        previous != null && previous != alias.declaration) {
      throw BindingDiagnostic(
        'NAPI_NAME',
        'Conflicting public record alias $name.',
        alias.source,
      );
    }
    names[name] = alias.declaration;
    records.putIfAbsent(alias.declaration, () => type);
  }
  final ordered = records.entries.toList()
    ..sort((a, b) => a.key.name.compareTo(b.key.name));
  return [
    for (final entry in ordered) ...[
      if (emitDocumentation(entry.value.alias!.documentation) case final comment
          when comment.isNotEmpty)
        comment,
      'export type ${entry.key.name} = ${_body(entry.value, classes, values)};',
    ],
  ].join('\n');
}

String _body(
  RecordTypeBinding type,
  List<ClassBinding> classes,
  List<ValueClassSchema> values,
) {
  final output = conversionFor(
    RecordTypeBinding(
      positional: type.positional,
      named: type.named,
      nullability: type.alias!.nullable
          ? TypeNullability.nullable
          : TypeNullability.nonNullable,
    ),
    type.alias!.declaration.name,
    bigint: false,
    classes: classes,
    valueSchemas: values,
  );
  for (final node in conversionGraph([output])) {
    if (node is ValueClassConversion) {
      node.typescriptName = node.classBinding.exportName;
    }
  }
  return output.typescriptType;
}

const _reserved = {
  ...javascriptReservedWords,
  'any',
  'unknown',
  'never',
  'number',
  'bigint',
  'boolean',
  'string',
  'symbol',
  'object',
  'undefined',
  'readonly',
  'keyof',
  'infer',
  'unique',
  'Promise',
  'Array',
  'ReadonlyArray',
  'Record',
  'PropertyKey',
  'Uint8Array',
  'globalThis',
};
