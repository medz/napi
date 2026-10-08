import 'exports.dart';

/// Generates declarations from the same signatures used by the Wasm bridge.
String generateTypescript(List<Export> exports) {
  final declarations = <String>[];
  for (final export in exports) {
    final usedNames = {
      for (final parameter in export.parameters)
        if (!javascriptKeywords.contains(parameter.name)) parameter.name,
    };
    final parameters = <String>[];
    var nextArgument = 0;
    for (final parameter in export.parameters) {
      var name = parameter.name;
      if (javascriptKeywords.contains(name)) {
        do {
          name = 'arg${nextArgument++}';
        } while (!usedNames.add(name));
      }
      parameters.add('$name: ${_type(parameter.type)}');
    }
    final valueType = _type(export.returnType);
    final returnType = export.isAsync ? 'Promise<$valueType>' : valueType;
    declarations.add(
      'export declare function ${export.name}(${parameters.join(', ')}): $returnType;',
    );
  }
  return '${declarations.join('\n')}\n';
}

String _type(ValueType type) {
  final name = switch (type.kind) {
    ValueKind.voidType => 'void',
    ValueKind.boolType => 'boolean',
    ValueKind.intType || ValueKind.doubleType => 'number',
    ValueKind.stringType => 'string',
    ValueKind.uint8ListType => 'Uint8Array',
    ValueKind.listType =>
      type.elementType!.nullable
          ? 'Array<${_type(type.elementType!)}>'
          : '${_type(type.elementType!)}[]',
    ValueKind.mapType => 'Record<string, ${_type(type.elementType!)}>',
  };
  return type.nullable ? '$name | null' : name;
}
