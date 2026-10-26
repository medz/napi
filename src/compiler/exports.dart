import 'package:kernel/ast.dart';
import 'package:package_config/package_config.dart';

enum ScalarKind {
  boolean,
  integer,
  doubleValue,
  number,
  string,
  bigint,
  nullValue,
  voidValue,
  never,
}

final class ExportType {
  const ExportType(this.dartType, this.kind, {this.nullable = false});

  final DartType dartType;
  final ScalarKind kind;
  final bool nullable;
}

final class ExportParameter {
  const ExportParameter({
    required this.name,
    required this.type,
    required this.required,
    required this.defaultValue,
  });

  final String name;
  final ExportType type;
  final bool required;
  final Expression? defaultValue;
}

final class ExportFunction {
  const ExportFunction({
    required this.target,
    required this.name,
    required this.positional,
    required this.named,
    required this.result,
  });

  final Procedure target;
  final String name;
  final List<ExportParameter> positional;
  final List<ExportParameter> named;
  final ExportType result;
}

List<ExportFunction> readExports(Library entry, PackageConfig packages) {
  final annotationUri = Uri.parse('package:napi/napi.dart');
  final annotationFile = packages.resolve(annotationUri);
  InstanceConstant? annotation(Annotatable node) {
    for (final expression in node.annotations) {
      if (expression is! ConstantExpression ||
          expression.constant is! InstanceConstant) {
        continue;
      }
      final constant = expression.constant as InstanceConstant;
      final declaration = constant.classNode;
      final library = declaration.enclosingLibrary;
      if (declaration.name == 'NAPI' &&
          (library.importUri == annotationUri ||
              library.fileUri == annotationFile)) {
        return constant;
      }
    }
    return null;
  }

  final declarations = <NamedNode>{
    ...entry.procedures,
    ...entry.fields,
    ...entry.classes,
    ...entry.typedefs,
    ...entry.extensions,
    ...entry.extensionTypeDeclarations,
    for (final reference in entry.additionalExports)
      if (reference.node case final NamedNode node) node,
  };
  final names = <String>{};
  final exports = <ExportFunction>[];
  for (final declaration in declarations) {
    if (declaration is! Annotatable) continue;
    final marker = annotation(declaration as Annotatable);
    if (marker == null) {
      if (declaration is Class) {
        for (final member in [
          ...declaration.constructors,
          ...declaration.procedures,
          ...declaration.fields,
        ]) {
          if (annotation(member) != null) {
            throw FormatException(
              'Unsupported annotated declaration: ${declaration.name}.${member.name.text}. '
              'This compiler currently exports top-level functions.',
            );
          }
        }
      }
      continue;
    }
    if (declaration is! Procedure ||
        declaration.enclosingClass != null ||
        declaration.kind != ProcedureKind.Method ||
        declaration.isExtensionMember ||
        declaration.isExtensionTypeMember) {
      throw const FormatException(
        'Unsupported annotated declaration: this compiler currently exports top-level functions.',
      );
    }
    final function = declaration.function;
    if (function.typeParameters.isNotEmpty) {
      throw FormatException(
        '@NAPI ${declaration.name.text}: generic functions are not supported yet.',
      );
    }
    if (function.dartAsyncMarker != AsyncMarker.Sync) {
      throw FormatException(
        '@NAPI ${declaration.name.text}: async and generator functions are not supported yet.',
      );
    }
    var name = declaration.name.text;
    for (final field in marker.fieldValues.entries) {
      if (field.key.asField.name.text == 'name' &&
          field.value is StringConstant) {
        name = (field.value as StringConstant).value;
      }
    }
    if (!RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$').hasMatch(name) ||
        _reservedNames.contains(name)) {
      throw FormatException(
        '@NAPI ${declaration.name.text}: invalid JavaScript export name "$name". '
        'Use a non-reserved ASCII identifier.',
      );
    }
    if (!names.add(name)) {
      throw FormatException('Duplicate JavaScript export: $name.');
    }
    ExportParameter parameter(FunctionParameter parameter, bool required) {
      final name = switch (parameter) {
        NamedParameter() => parameter.parameterName,
        _ => parameter.cosmeticName ?? 'argument',
      };
      return ExportParameter(
        name: name,
        type: _readType(
          parameter.type,
          '${declaration.name.text}: parameter $name',
          result: false,
        ),
        required: required,
        defaultValue: parameter.defaultValue,
      );
    }

    exports.add(
      ExportFunction(
        target: declaration,
        name: name,
        positional: [
          for (var i = 0; i < function.positionalParameters.length; ++i)
            parameter(
              function.positionalParameters[i],
              i < function.requiredParameterCount,
            ),
        ],
        named: [
          for (final value in function.namedParameters)
            parameter(value, value.isRequired),
        ],
        result: _readType(
          function.returnType,
          '${declaration.name.text}: return',
          result: true,
        ),
      ),
    );
  }
  return exports;
}

const _reservedNames = {
  'arguments',
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'debugger',
  'default',
  'delete',
  'do',
  'else',
  'enum',
  'eval',
  'export',
  'extends',
  'false',
  'finally',
  'for',
  'function',
  'if',
  'implements',
  'import',
  'in',
  'instanceof',
  'interface',
  'let',
  'new',
  'null',
  'package',
  'private',
  'protected',
  'public',
  'return',
  'static',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'typeof',
  'var',
  'void',
  'while',
  'with',
  'yield',
};

ExportType _readType(DartType type, String context, {required bool result}) {
  if (type is NullType) return ExportType(type, ScalarKind.nullValue);
  if (type is NeverType) {
    return ExportType(
      type,
      type.nullability == Nullability.nullable
          ? ScalarKind.nullValue
          : ScalarKind.never,
    );
  }
  if (result && type is VoidType) return ExportType(type, ScalarKind.voidValue);
  if (type is InterfaceType &&
      type.classNode.enclosingLibrary.importUri.toString() == 'dart:core') {
    final kind = switch (type.classNode.name) {
      'bool' => ScalarKind.boolean,
      'int' => ScalarKind.integer,
      'double' => ScalarKind.doubleValue,
      'num' => ScalarKind.number,
      'String' => ScalarKind.string,
      'BigInt' => ScalarKind.bigint,
      _ => null,
    };
    if (kind != null) {
      return ExportType(
        type,
        kind,
        nullable: type.nullability == Nullability.nullable,
      );
    }
  }
  throw FormatException(
    '@NAPI $context: unsupported ${result ? 'return' : 'parameter'} type $type.',
  );
}
