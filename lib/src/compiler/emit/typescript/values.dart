import 'dart:convert';

import '../../analysis/validate.dart';
import '../../ir/model.dart';
import '../../lowering/plan.dart';
import 'documentation.dart';

/// Allocate every recursive alias before expanding any body. Names are private;
/// the selected public name denotes only the ordinary output representation.
String emitValueDeclarations(
  List<ClassBinding> classes,
  List<ValueClassSchema> schemas,
  Iterable<ValueConversion> conversions, {
  Set<String> reservedNames = const {},
}) {
  if (schemas.isEmpty) return '';
  final defaults = [
    for (final schema in schemas)
      conversionFor(
        valueClassType(schema.binding),
        schema.binding.exportName,
        bigint: false,
        classes: classes,
        valueSchemas: schemas,
        opaqueParameters: opaqueParameterIds(schema.binding.typeParameters),
      ) as ValueClassConversion,
  ];
  final nodes = conversionDependencies([...conversions, ...defaults])
      .whereType<ValueClassConversion>()
      .toList();
  final representatives =
      <(ClassBinding, ValueDirection, bool), ValueClassConversion>{};
  final aliases = <(ClassBinding, ValueDirection, bool), String>{};
  final used = {...reservedNames, for (final c in classes) c.exportName};
  var next = 0;
  for (final node in nodes) {
    final key = (node.classBinding, node.direction, node.bigint);
    if (!aliases.containsKey(key)) {
      String name;
      do {
        name = '\$value${next++}';
      } while (!used.add(name));
      aliases[key] = name;
      representatives[key] = node.classBinding.typeParameters.isEmpty
          ? node
          : conversionFor(
              valueClassType(node.classBinding),
              node.classBinding.exportName,
              bigint: node.bigint,
              classes: classes,
              valueSchemas: schemas,
              direction: node.direction,
              opaqueParameters: opaqueParameterIds(
                node.classBinding.typeParameters,
              ),
            ) as ValueClassConversion;
    }
  }
  for (final node in [
    ...nodes,
    ...conversionDependencies(representatives.values)
        .whereType<ValueClassConversion>(),
  ]) {
    final key = (node.classBinding, node.direction, node.bigint);
    node.typescriptName = aliases[key]!;
  }
  return [
    for (final entry in representatives.entries)
      'type ${aliases[entry.key]}${_parameters(entry.value.classBinding)} = ${_body(entry.value)};',
    for (final node in defaults) ...[
      if (node.classBinding.documentation != null)
        emitDocumentation(node.classBinding.documentation),
      'export type ${node.classBinding.exportName}${_parameters(node.classBinding, defaults: true)} = ${node.typescriptName}${_parameters(node.classBinding)};',
    ],
  ].join('\n');
}

String _parameters(ClassBinding binding, {bool defaults = false}) =>
    binding.typeParameters.isEmpty
    ? ''
    : '<${binding.typeParameters.map((p) => '${p.declaration.name}${defaults ? ' = unknown' : ''}').join(', ')}>';

String _body(ValueClassConversion node) {
  if (node.direction == ValueDirection.input && node.constructor == null) {
    return 'never';
  }
  if (node.fields.isEmpty) return '{ [key: string]: never }';
  String property(ValueClassField field) =>
      '${jsonEncode(field.name)}${field.optional ? '?' : ''}: ${field.conversion.typescriptType}${field.optional && !field.opaqueOptional ? ' | undefined' : ''}';
  if (node.fields.every((field) => field.documentation == null)) {
    return '{ ${node.fields.map(property).join('; ')} }';
  }
  return [
    '{',
    for (final field in node.fields) ...[
      if (field.documentation != null)
        emitDocumentation(field.documentation, indent: '  '),
      '  ${property(field)};',
    ],
    '}',
  ].join('\n');
}
