import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/type_algebra.dart';
import 'package:package_config/package_config.dart';

enum ValueKind {
  boolean,
  integer,
  doubleValue,
  number,
  string,
  bigint,
  nullValue,
  voidValue,
  never,
  object,
  list,
  map,
  typedData,
}

enum TypedDataKind {
  int8,
  uint8,
  uint8Clamped,
  int16,
  uint16,
  int32,
  uint32,
  int64,
  uint64,
  float32,
  float64,
}

final class ExportType {
  const ExportType(
    this.dartType,
    this.kind, {
    this.nullable = false,
    this.classExport,
    this.element,
    this.typedDataKind,
  });
  final DartType dartType;
  final ValueKind kind;
  final bool nullable;
  final ExportClass? classExport;
  final ExportType? element;
  final TypedDataKind? typedDataKind;
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
    required this.signature,
    this.owner,
    this.constructor = false,
  });
  final Member target;
  final String name;
  final List<ExportParameter> positional;
  final List<ExportParameter> named;
  final ExportType result;
  final FunctionType signature;
  final ExportClass? owner;
  final bool constructor;
  bool get instance => !constructor && target.isInstanceMember;
}

final class ExportProperty {
  const ExportProperty({
    required this.name,
    required this.owner,
    this.getter,
    this.setter,
    this.readType,
    this.writeType,
  });
  final String name;
  final ExportClass owner;
  final Member? getter;
  final Member? setter;
  final ExportType? readType;
  final ExportType? writeType;
  bool get instance => (getter ?? setter)!.isInstanceMember;
}

final class ExportClass {
  ExportClass(this.target, this.name);
  final Class target;
  final String name;
  ExportFunction? constructor;
  final methods = <ExportFunction>[];
  final properties = <ExportProperty>[];
  final staticMethods = <ExportFunction>[];
  final staticProperties = <ExportProperty>[];
  InterfaceType get dartType => InterfaceType(target, Nullability.nonNullable);
}

final class ExportModule {
  final functions = <ExportFunction>[];
  final classes = <ExportClass>[];
  bool get isEmpty => functions.isEmpty && classes.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

ExportModule readExports(
  Component component,
  Library entry,
  PackageConfig packages,
) => _Reader(component, packages).read(entry);

final class _Reader {
  _Reader(Component component, PackageConfig packages)
    : annotationFile = packages.resolve(_annotationUri),
      hierarchy = ClassHierarchy(component, CoreTypes(component));

  static final _annotationUri = Uri.parse('package:napi/napi.dart');
  final Uri? annotationFile;
  final ClassHierarchy hierarchy;
  final module = ExportModule();
  final classes = <Class, ExportClass>{};

  InstanceConstant? _annotation(Annotatable node) {
    for (final expression in node.annotations) {
      if (expression is! ConstantExpression ||
          expression.constant is! InstanceConstant)
        continue;
      final constant = expression.constant as InstanceConstant;
      final declaration = constant.classNode;
      final library = declaration.enclosingLibrary;
      if (declaration.name == 'NAPI' &&
          (library.importUri == _annotationUri ||
              library.fileUri == annotationFile))
        return constant;
    }
    return null;
  }

  String? _rename(Annotatable node) {
    final marker = _annotation(node);
    if (marker == null) return null;
    for (final field in marker.fieldValues.entries) {
      if (field.key.asField.name.text == 'name' &&
          field.value is StringConstant)
        return (field.value as StringConstant).value;
    }
    return null;
  }

  String _name(Annotatable node, String fallback) =>
      _checkName(_rename(node) ?? fallback);

  ExportModule read(Library entry) {
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
    final selected = <NamedNode>[];
    final names = <String>{};
    for (final declaration in declarations) {
      if (declaration is! Annotatable ||
          _annotation(declaration as Annotatable) == null)
        continue;
      if (declaration is Class &&
          !declaration.isEnum &&
          declaration.typeParameters.isEmpty) {
        final name = _name(declaration, declaration.name);
        if (_reservedTypeNames.contains(name)) {
          throw FormatException(
            '@NAPI: "$name" is a reserved TypeScript class name. '
            'Choose another name with @NAPI(name: ...).',
          );
        }
        final exported = ExportClass(declaration, name);
        if (!names.add(exported.name))
          throw FormatException(
            'Duplicate JavaScript export: ${exported.name}.',
          );
        module.classes.add(exported);
        classes[declaration] = exported;
      } else if (declaration is Procedure &&
          declaration.enclosingClass == null &&
          declaration.kind == ProcedureKind.Method &&
          !declaration.isExtensionMember &&
          !declaration.isExtensionTypeMember) {
        selected.add(declaration);
      } else {
        throw const FormatException(
          'Unsupported annotated declaration: export a non-generic class or a top-level function.',
        );
      }
    }
    for (final cls in module.classes) {
      for (final other in module.classes) {
        if (cls != other &&
            hierarchy.getClassAsInstanceOf(cls.target, other.target) != null) {
          throw FormatException(
            'Exported classes cannot inherit from or implement another exported class: ${cls.name}, ${other.name}.',
          );
        }
      }
      _class(cls);
    }
    for (final declaration in selected.cast<Procedure>()) {
      final name = _name(declaration, declaration.name.text);
      if (!names.add(name))
        throw FormatException('Duplicate JavaScript export: $name.');
      module.functions.add(_function(declaration, name));
    }
    for (final declaration in declarations.whereType<Class>()) {
      if (classes.containsKey(declaration)) continue;
      for (final member in [
        ...declaration.constructors,
        ...declaration.procedures,
        ...declaration.fields,
      ]) {
        if (_annotation(member) != null)
          throw FormatException(
            'Unsupported annotated declaration: ${declaration.name}.${member.name.text} belongs to a class that is not exported.',
          );
      }
    }
    return module;
  }

  Substitution _substitution(ExportClass? owner, Member member) {
    final declaration = member.enclosingClass;
    if (owner == null || declaration == null) return Substitution.empty;
    final type = hierarchy.getClassAsInstanceOf(owner.target, declaration);
    return type == null ? Substitution.empty : Substitution.fromSupertype(type);
  }

  ExportFunction _function(
    Member target,
    String name, {
    ExportClass? owner,
    bool constructor = false,
  }) {
    final function = target is Constructor
        ? target.function
        : (target as Procedure).function;
    if (function.typeParameters.isNotEmpty)
      throw FormatException(
        '@NAPI $name: generic functions are not supported yet.',
      );
    if (function.dartAsyncMarker != AsyncMarker.Sync)
      throw FormatException(
        '@NAPI $name: async and generator functions are not supported yet.',
      );
    final substitution = _substitution(owner, target);
    ExportParameter parameter(FunctionParameter parameter, bool required) {
      final parameterName = parameter is NamedParameter
          ? parameter.parameterName
          : parameter.cosmeticName ?? 'argument';
      return ExportParameter(
        name: parameterName,
        type: _type(
          substitution.substituteType(parameter.type),
          '$name: parameter $parameterName',
        ),
        required: required,
        defaultValue: parameter.defaultValue,
      );
    }

    return ExportFunction(
      target: target,
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
      result: constructor
          ? _type(owner!.dartType, name)
          : _type(
              substitution.substituteType(function.returnType),
              '$name: return',
              result: true,
            ),
      signature:
          substitution.substituteType(
                function.computeFunctionType(Nullability.nonNullable),
              )
              as FunctionType,
      owner: owner,
      constructor: constructor,
    );
  }

  bool _visible(Member member) =>
      !member.name.isPrivate || _annotation(member) != null;

  void _class(ExportClass cls) {
    final constructors = <Member>[
      if (!cls.target.isAbstract) ...cls.target.constructors,
      ...cls.target.procedures.where((member) => member.isFactory),
    ];
    final staticNames = <String>{};
    for (final target in constructors.where(_visible)) {
      if (target.name.text.isEmpty) {
        if (_rename(target) != null)
          throw FormatException(
            '@NAPI ${cls.name}: rename the class, not its unnamed constructor.',
          );
        cls.constructor = _function(
          target,
          cls.name,
          owner: cls,
          constructor: true,
        );
      } else {
        final name = _name(target, target.name.text);
        _memberName(cls, name, staticNames, static: true);
        cls.staticMethods.add(
          _function(target, name, owner: cls, constructor: true),
        );
      }
    }
    final readable = hierarchy
        .getInterfaceMembers(cls.target)
        .where(
          (member) =>
              member.enclosingClass != hierarchy.coreTypes.objectClass &&
              _visible(member),
        );
    final writable = hierarchy
        .getInterfaceMembers(cls.target, setters: true)
        .where(_visible);
    _members(cls, readable, writable, <String>{}, static: false);
    _members(
      cls,
      [
        ...cls.target.fields.where((member) => member.isStatic),
        ...cls.target.procedures.where(
          (member) => member.isStatic && !member.isFactory && !member.isSetter,
        ),
      ].where(_visible),
      [
        ...cls.target.fields.where(
          (member) => member.isStatic && member.hasSetter,
        ),
        ...cls.target.procedures.where(
          (member) => member.isStatic && member.isSetter,
        ),
      ].where(_visible),
      staticNames,
      static: true,
    );
  }

  void _memberName(
    ExportClass cls,
    String name,
    Set<String> names, {
    required bool static,
  }) {
    if (static && name == 'prototype') {
      throw FormatException(
        '@NAPI ${cls.name}: reserved ${static ? 'static' : 'instance'} member name "$name".',
      );
    }
    if (!names.add(name))
      throw FormatException('Duplicate JavaScript member: ${cls.name}.$name.');
  }

  void _members(
    ExportClass cls,
    Iterable<Member> readable,
    Iterable<Member> writable,
    Set<String> names, {
    required bool static,
  }) {
    final getters = <Name, Member>{};
    final setters = <Name, Member>{
      for (final member in writable) member.name: member,
    };
    for (final member in readable) {
      if (member is Procedure && member.kind == ProcedureKind.Method) {
        final name = _name(member, member.name.text);
        _memberName(cls, name, names, static: static);
        (static ? cls.staticMethods : cls.methods).add(
          _function(member, name, owner: cls),
        );
      } else if (member is Field || member is Procedure && member.isGetter) {
        getters[member.name] = member;
      } else if (_annotation(member) != null) {
        throw FormatException(
          'Unsupported annotated declaration: ${cls.name}.${member.name.text}.',
        );
      }
    }
    for (final key in {...getters.keys, ...setters.keys}) {
      final getter = getters[key];
      final setter = setters[key];
      final readName = getter == null ? null : _rename(getter);
      final writeName = setter == null ? null : _rename(setter);
      if (readName != null && writeName != null && readName != writeName)
        throw FormatException(
          '@NAPI ${cls.name}.${key.text}: getter and setter names must agree.',
        );
      final name = _checkName(readName ?? writeName ?? key.text);
      _memberName(cls, name, names, static: static);
      final readType = getter == null
          ? null
          : _type(
              _substitution(cls, getter).substituteType(
                getter is Field
                    ? getter.type
                    : (getter as Procedure).function.returnType,
              ),
              '${cls.name}.$name: return',
              result: true,
            );
      final writeType = setter == null
          ? null
          : _type(
              _substitution(cls, setter).substituteType(
                setter is Field
                    ? setter.type
                    : (setter as Procedure)
                          .function
                          .positionalParameters
                          .single
                          .type,
              ),
              '${cls.name}.$name: parameter',
            );
      (static ? cls.staticProperties : cls.properties).add(
        ExportProperty(
          name: name,
          owner: cls,
          getter: getter,
          setter: setter,
          readType: readType,
          writeType: writeType,
        ),
      );
    }
  }

  ExportType _type(DartType type, String context, {bool result = false}) {
    if (type is NullType) return ExportType(type, ValueKind.nullValue);
    if (type is NeverType)
      return ExportType(
        type,
        type.nullability == Nullability.nullable
            ? ValueKind.nullValue
            : ValueKind.never,
      );
    if (result && type is VoidType)
      return ExportType(type, ValueKind.voidValue);
    if (type is InterfaceType) {
      final exported = classes[type.classNode];
      if (exported != null)
        return ExportType(
          type,
          ValueKind.object,
          nullable: type.nullability == Nullability.nullable,
          classExport: exported,
        );
      final library = type.classNode.enclosingLibrary.importUri.toString();
      if (library == 'dart:core') {
        if (type.classNode.name == 'List') {
          return ExportType(
            type,
            ValueKind.list,
            nullable: type.nullability == Nullability.nullable,
            element: _type(type.typeArguments.single, '$context: List element'),
          );
        }
        if (type.classNode.name == 'Map') {
          final key = type.typeArguments.first;
          if (key is! InterfaceType ||
              key.classNode != hierarchy.coreTypes.stringClass ||
              key.nullability != Nullability.nonNullable) {
            throw FormatException(
              '@NAPI $context: Map keys must be non-nullable String.',
            );
          }
          return ExportType(
            type,
            ValueKind.map,
            nullable: type.nullability == Nullability.nullable,
            element: _type(type.typeArguments.last, '$context: Map value'),
          );
        }
        final kind = switch (type.classNode.name) {
          'bool' => ValueKind.boolean,
          'int' => ValueKind.integer,
          'double' => ValueKind.doubleValue,
          'num' => ValueKind.number,
          'String' => ValueKind.string,
          'BigInt' => ValueKind.bigint,
          _ => null,
        };
        if (kind != null)
          return ExportType(
            type,
            kind,
            nullable: type.nullability == Nullability.nullable,
          );
      } else if (library == 'dart:typed_data') {
        final kind = switch (type.classNode.name) {
          'Int8List' => TypedDataKind.int8,
          'Uint8List' => TypedDataKind.uint8,
          'Uint8ClampedList' => TypedDataKind.uint8Clamped,
          'Int16List' => TypedDataKind.int16,
          'Uint16List' => TypedDataKind.uint16,
          'Int32List' => TypedDataKind.int32,
          'Uint32List' => TypedDataKind.uint32,
          'Int64List' => TypedDataKind.int64,
          'Uint64List' => TypedDataKind.uint64,
          'Float32List' => TypedDataKind.float32,
          'Float64List' => TypedDataKind.float64,
          _ => null,
        };
        if (kind != null) {
          return ExportType(
            type,
            ValueKind.typedData,
            nullable: type.nullability == Nullability.nullable,
            typedDataKind: kind,
          );
        }
      } else if (!type.classNode.enclosingLibrary.importUri.isScheme('dart')) {
        throw FormatException(
          '@NAPI $context: class type must be exported: ${type.classNode.name}.',
        );
      }
    }
    throw FormatException(
      '@NAPI $context: unsupported ${result ? 'return' : 'parameter'} type $type.',
    );
  }
}

String _checkName(String name) {
  if (!RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$').hasMatch(name) ||
      _reservedNames.contains(name))
    throw FormatException(
      '@NAPI: invalid JavaScript export name "$name". Use a non-reserved ASCII identifier.',
    );
  return name;
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

const _reservedTypeNames = {
  'any',
  'unknown',
  'never',
  'number',
  'bigint',
  'boolean',
  'string',
  'symbol',
  'void',
  'object',
  'undefined',
};
