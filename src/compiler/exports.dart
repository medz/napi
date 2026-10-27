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
  dateTime,
  function,
  future,
  stream,
  record,
  enumeration,
  jsReference,
  undefined,
  opaque,
  dynamicValue,
  typeParameter,
}

enum JsReferenceKind { object, function, symbol }

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
    this.signature,
    this.recordFields,
    this.enumExport,
    this.referenceKind,
    this.parameter,
    this.representation,
    this.typeArguments = const [],
  });
  final DartType dartType;
  final ExportTypeParameter? parameter;
  final ExportType? representation;
  final List<ExportType> typeArguments;
  final ValueKind kind;
  final bool nullable;
  final ExportClass? classExport;
  final ExportEnum? enumExport;
  final JsReferenceKind? referenceKind;
  final ExportType? element;
  final TypedDataKind? typedDataKind;
  final ExportSignature? signature;
  final ({List<ExportType> positional, Map<String, ExportType> named})?
  recordFields;
}

final class ExportTypeParameter {
  ExportTypeParameter(this.target, this.actualType);
  final TypeParameter target;
  final DartType actualType;
  String get name => target.name!;
  late final ExportType bound;
  late final ExportType defaultType;
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

final class ExportSignature {
  const ExportSignature({
    required this.type,
    required this.positional,
    required this.named,
    required this.result,
    this.typeParameters = const [],
  });
  final FunctionType type;
  final List<ExportTypeParameter> typeParameters;
  final List<ExportParameter> positional;
  final List<ExportParameter> named;
  final ExportType result;
}

final class ExportFunction {
  const ExportFunction({
    required this.target,
    required this.name,
    required this.signature,
    this.owner,
    this.constructor = false,
    this.typeArguments = const [],
    this.tearOffType,
  });
  final Member target;
  final List<DartType> typeArguments;
  final FunctionType? tearOffType;
  final String name;
  final ExportSignature signature;
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
  final ExportClass? owner;
  final Member? getter;
  final Member? setter;
  final ExportType? readType;
  final ExportType? writeType;
  bool get instance => (getter ?? setter)!.isInstanceMember;
}

final class ExportClass {
  ExportClass(this.target, this.name, {this.isObject = false});
  final Class target;
  final String name;
  final bool isObject;
  final typeParameters = <ExportTypeParameter>[];
  ExportFunction? constructor;
  final methods = <ExportFunction>[];
  final properties = <ExportProperty>[];
  final staticMethods = <ExportFunction>[];
  final staticProperties = <ExportProperty>[];
  InterfaceType get dartType => InterfaceType(target, Nullability.nonNullable, [
    for (final parameter in typeParameters) parameter.actualType,
  ]);
}

final class ExportModule {
  final functions = <ExportFunction>[];
  final classes = <ExportClass>[];
  final enums = <ExportEnum>[];
  final constants = <ExportConstant>[];
  final properties = <ExportProperty>[];
  bool get isEmpty =>
      functions.isEmpty &&
      classes.isEmpty &&
      enums.isEmpty &&
      constants.isEmpty &&
      properties.isEmpty;
  bool get isNotEmpty => !isEmpty;
}

final class ExportConstant {
  const ExportConstant(this.target, this.name, this.type);
  final Field target;
  final String name;
  final ExportType type;
}

final class ExportEnum {
  const ExportEnum(this.target, this.name, this.values, this.cases);
  final Class target;
  final String name;
  final Field values;
  final List<({String name, int index})> cases;
  InterfaceType get dartType => InterfaceType(target, Nullability.nonNullable);
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
  final enums = <Class, ExportEnum>{};
  final _parameters = <TypeParameter, ExportTypeParameter>{};

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

  bool _objectAnnotation(Annotatable node) =>
      _annotation(node)?.fieldValues.entries.any(
        (entry) =>
            entry.key.asField.name.text == '_object' &&
            entry.value is BoolConstant &&
            (entry.value as BoolConstant).value,
      ) ??
      false;

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
    final selected = <Member>[];
    final readable = <Member>[];
    final writable = <Member>[];
    final names = <String>{};
    for (final declaration in declarations) {
      if (declaration is! Annotatable ||
          _annotation(declaration as Annotatable) == null)
        continue;
      if (_objectAnnotation(declaration as Annotatable) &&
          (declaration is! Class ||
              declaration.isEnum ||
              declaration.typeParameters.isNotEmpty)) {
        throw const FormatException(
          '@NAPI.object can only annotate a non-generic class.',
        );
      }
      if (declaration is Class) {
        final name = _name(declaration, declaration.name);
        if (_reservedTypeNames.contains(name)) {
          throw FormatException(
            '@NAPI: "$name" is a reserved TypeScript ${declaration.isEnum ? 'enum' : 'class'} name. '
            'Choose another name with @NAPI(name: ...).',
          );
        }
        if (!names.add(name))
          throw FormatException('Duplicate JavaScript export: $name.');
        if (declaration.isEnum) {
          final exported = _enum(declaration, name);
          module.enums.add(exported);
          enums[declaration] = exported;
        } else {
          final exported = ExportClass(
            declaration,
            name,
            isObject: _objectAnnotation(declaration),
          );
          module.classes.add(exported);
          classes[declaration] = exported;
        }
      } else if (declaration is Procedure &&
          declaration.enclosingClass == null &&
          !declaration.isExtensionMember &&
          !declaration.isExtensionTypeMember) {
        switch (declaration.kind) {
          case ProcedureKind.Method:
            selected.add(declaration);
          case ProcedureKind.Getter:
            readable.add(declaration);
          case ProcedureKind.Setter:
            writable.add(declaration);
          default:
            throw const FormatException(
              'Unsupported annotated top-level declaration.',
            );
        }
      } else if (declaration is Field && declaration.enclosingClass == null) {
        if (declaration.isConst) {
          selected.add(declaration);
        } else {
          readable.add(declaration);
          if (!declaration.isFinal && declaration.hasSetter)
            writable.add(declaration);
        }
      } else {
        throw const FormatException(
          'Unsupported annotated declaration: export a class, enum, top-level function or property.',
        );
      }
    }
    for (final cls in module.classes) {
      cls.typeParameters.addAll(
        _typeParameters(cls.target.typeParameters, cls.name),
      );
      _parameters.clear();
    }
    for (final cls in module.classes) {
      _parameters.addAll({
        for (final parameter in cls.typeParameters) parameter.target: parameter,
      });
      for (final other in module.classes) {
        if (cls != other &&
            hierarchy.getClassAsInstanceOf(cls.target, other.target) != null) {
          throw FormatException(
            'Exported classes cannot inherit from or implement another exported class: ${cls.name}, ${other.name}.',
          );
        }
      }
      if (cls.isObject) {
        _objectClass(cls);
      } else {
        _class(cls);
      }
      _parameters.clear();
    }
    for (final declaration in selected) {
      final name = _name(declaration, declaration.name.text);
      if (!names.add(name))
        throw FormatException('Duplicate JavaScript export: $name.');
      if (declaration is Field) {
        module.constants.add(
          ExportConstant(
            declaration,
            name,
            _type(declaration.type, '$name: constant'),
          ),
        );
      } else {
        module.functions.add(_function(declaration, name));
      }
    }
    _members(null, readable, writable, names, static: true);
    final exportedMembers = <Member>{
      for (final cls in module.classes) ...[
        if (cls.constructor != null) cls.constructor!.target,
        for (final method in [...cls.methods, ...cls.staticMethods])
          method.target,
        for (final property in [
          ...cls.properties,
          ...cls.staticProperties,
        ]) ...[
          if (property.getter != null) property.getter!,
          if (property.setter != null) property.setter!,
        ],
      ],
    };
    for (final declaration in declarations.whereType<Class>()) {
      if (classes.containsKey(declaration) || enums.containsKey(declaration))
        continue;
      for (final member in [
        ...declaration.constructors,
        ...declaration.procedures,
        ...declaration.fields,
      ]) {
        if (_annotation(member) != null && !exportedMembers.contains(member))
          throw FormatException(
            'Unsupported annotated declaration: ${declaration.name}.${member.name.text} belongs to a class that is not exported.',
          );
      }
    }
    return module;
  }

  ExportEnum _enum(Class target, String name) {
    final cases = <({String name, int index})>[];
    final names = <String>{};
    for (final member in [
      ...target.fields,
      ...target.constructors,
      ...target.procedures,
    ]) {
      _isExported(member);
      if (member is Field && member.isEnumElement) {
        if (member.name.isPrivate && _annotation(member) == null) {
          throw FormatException(
            '@NAPI $name: Private enum case must be explicitly annotated: ${member.name.text}.',
          );
        }
        final caseName = _name(member, member.name.text);
        if (!names.add(caseName)) {
          throw FormatException(
            'Duplicate JavaScript enum case: $name.$caseName.',
          );
        }
        final value =
            (member.initializer as ConstantExpression).constant
                as InstanceConstant;
        final index =
            value.fieldValues.entries
                    .singleWhere(
                      (entry) =>
                          entry.key.asField.name.text == 'index' &&
                          entry.key.asField.enclosingLibrary.importUri
                                  .toString() ==
                              'dart:core',
                    )
                    .value
                as IntConstant;
        cases.add((name: caseName, index: index.value));
      } else if (_annotation(member) != null) {
        throw FormatException(
          '@NAPI $name: Only enum cases can be annotated: ${member.name.text}.',
        );
      }
    }
    return ExportEnum(
      target,
      name,
      target.fields.singleWhere((field) => field.name.text == 'values'),
      cases,
    );
  }

  Substitution _substitution(ExportClass? owner, Member member) {
    final declaration = member.enclosingClass;
    if (owner == null || declaration == null) return Substitution.empty;
    final type = hierarchy.getClassAsInstanceOf(owner.target, declaration);
    return type == null ? Substitution.empty : Substitution.fromSupertype(type);
  }

  DartType _actual(DartType type) => Substitution.fromMap({
    for (final entry in _parameters.entries) entry.key: entry.value.actualType,
  }).substituteType(type);

  List<ExportTypeParameter> _typeParameters(
    List<TypeParameter> parameters,
    String context, {
    Substitution substitution = Substitution.empty,
  }) {
    final models = [
      for (final parameter in parameters)
        ExportTypeParameter(
          parameter,
          _actual(substitution.substituteType(parameter.defaultType)),
        ),
    ];
    _parameters.addAll({for (final model in models) model.target: model});
    for (final model in models) {
      model.bound = _type(
        substitution.substituteType(model.target.bound),
        '$context: bound ${model.name}',
      );
      ExportType representation = model.bound;
      while (representation.kind == ValueKind.typeParameter) {
        representation = representation.representation!;
      }
      if (!const {
        ValueKind.boolean,
        ValueKind.integer,
        ValueKind.doubleValue,
        ValueKind.number,
        ValueKind.string,
        ValueKind.bigint,
        ValueKind.nullValue,
        ValueKind.never,
        ValueKind.opaque,
        ValueKind.dynamicValue,
        ValueKind.jsReference,
        ValueKind.undefined,
      }.contains(representation.kind)) {
        throw FormatException(
          '@NAPI $context: generic bounds must preserve JavaScript values: ${model.name}.',
        );
      }
      model.defaultType = _type(
        substitution.substituteType(model.target.defaultType),
        '$context: default ${model.name}',
      );
    }
    return models;
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
    _checkAsync(function, name);
    final savedParameters = Map<TypeParameter, ExportTypeParameter>.of(
      _parameters,
    );
    try {
      final substitution = _substitution(owner, target);
      final List<ExportTypeParameter> typeParameters;
      if (constructor) {
        typeParameters = owner!.typeParameters;
        // Factory procedures have copies of their class's type parameters.
        for (var i = 0; i < function.typeParameters.length; ++i) {
          _parameters[function.typeParameters[i]] = typeParameters[i];
        }
      } else {
        typeParameters = _typeParameters(
          function.typeParameters,
          name,
          substitution: substitution,
        );
      }
      ExportParameter parameter(FunctionParameter parameter, bool required) {
        final parameterName =
            constructor && owner!.isObject && parameter.isWildcard
            ? '_'
            : parameter is NamedParameter
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

      final rawType =
          _actual(
                substitution.substituteType(
                  function.computeFunctionType(Nullability.nonNullable),
                ),
              )
              as FunctionType;
      final arguments = constructor
          ? owner!.typeParameters
                .map((parameter) => parameter.actualType)
                .toList()
          : rawType.typeParameters
                .map((parameter) => parameter.defaultType)
                .toList();
      final invocationType = rawType.typeParameters.isEmpty
          ? rawType
          : FunctionTypeInstantiator.instantiate(rawType, arguments);
      return ExportFunction(
        target: target,
        name: name,
        signature: ExportSignature(
          typeParameters: typeParameters,
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
              ? _type(
                  InterfaceType(owner!.target, Nullability.nonNullable, [
                    for (final parameter in owner.typeParameters)
                      TypeParameterType(
                        parameter.target,
                        Nullability.nonNullable,
                      ),
                  ]),
                  name,
                )
              : _type(
                  substitution.substituteType(function.returnType),
                  '$name: return',
                  result: true,
                ),
          type: invocationType,
        ),
        owner: owner,
        constructor: constructor,
        typeArguments: arguments,
        tearOffType: rawType,
      );
    } finally {
      _parameters
        ..clear()
        ..addAll(savedParameters);
    }
  }

  void _checkAsync(FunctionNode function, String name) {
    if (function.dartAsyncMarker == AsyncMarker.Async &&
        function.returnType is VoidType) {
      throw FormatException(
        '@NAPI $name: async void exports are not supported; return Future<void> instead.',
      );
    }
    if (function.dartAsyncMarker != AsyncMarker.Sync &&
        function.dartAsyncMarker != AsyncMarker.Async &&
        function.dartAsyncMarker != AsyncMarker.AsyncStar)
      throw FormatException(
        '@NAPI $name: sync* generator functions are not supported yet.',
      );
  }

  bool _isExported(Member member) {
    if (_objectAnnotation(member)) {
      throw const FormatException(
        '@NAPI.object can only annotate a non-generic class.',
      );
    }
    return _annotation(member) != null;
  }

  void _objectClass(ExportClass cls) {
    final constructors = <Member>[
      ...cls.target.constructors,
      ...cls.target.procedures.where((member) => member.isFactory),
    ].where(_isExported).toList();
    if (constructors.length > 1) {
      throw FormatException(
        '@NAPI.object ${cls.name}: multiple annotated input constructors.',
      );
    }
    if (constructors.isNotEmpty) {
      final target = constructors.single;
      if (cls.target.isAbstract && target is Constructor) {
        throw FormatException(
          '@NAPI.object ${cls.name}: an abstract class requires a factory input constructor.',
        );
      }
      if (_rename(target) != null) {
        throw FormatException(
          '@NAPI.object ${cls.name}: input constructors have no JavaScript name to rename.',
        );
      }
      cls.constructor = _function(
        target,
        cls.name,
        owner: cls,
        constructor: true,
      );
      final names = <String>{};
      final signature = cls.constructor!.signature;
      for (final parameter in [...signature.positional, ...signature.named]) {
        if (!names.add(parameter.name)) {
          throw FormatException(
            '@NAPI.object ${cls.name}: duplicate object input property: ${parameter.name}.',
          );
        }
      }
    }
    for (final member in [...cls.target.fields, ...cls.target.procedures]) {
      if (!_isExported(member) || member is Procedure && member.isFactory)
        continue;
      if (!member.isInstanceMember || member is Procedure && !member.isGetter) {
        throw FormatException(
          '@NAPI.object ${cls.name}: only instance fields and getters can be exported as object properties: ${member.name.text}.',
        );
      }
    }
    _members(
      cls,
      hierarchy
          .getInterfaceMembers(cls.target)
          .where(
            (member) =>
                member.enclosingClass != hierarchy.coreTypes.objectClass &&
                _isExported(member),
          ),
      const [],
      <String>{},
      static: false,
    );
  }

  void _class(ExportClass cls) {
    final constructors = <Member>[
      if (!cls.target.isAbstract) ...cls.target.constructors,
      ...cls.target.procedures.where((member) => member.isFactory),
    ];
    final staticNames = <String>{};
    for (final target in constructors.where(_isExported)) {
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
              _isExported(member),
        );
    final writable = hierarchy
        .getInterfaceMembers(cls.target, setters: true)
        .where(
          (member) =>
              _isExported(member) && !(member is Field && member.isFinal),
        );
    _members(cls, readable, writable, <String>{}, static: false);
    _members(
      cls,
      [
        ...cls.target.fields.where((member) => member.isStatic),
        ...cls.target.procedures.where(
          (member) => member.isStatic && !member.isFactory && !member.isSetter,
        ),
      ].where(_isExported),
      [
        ...cls.target.fields.where(
          (member) => member.isStatic && member.hasSetter && !member.isFinal,
        ),
        ...cls.target.procedures.where(
          (member) => member.isStatic && member.isSetter,
        ),
      ].where(_isExported),
      staticNames,
      static: true,
    );
  }

  void _memberName(
    ExportClass? cls,
    String name,
    Set<String> names, {
    required bool static,
  }) {
    if (cls != null && static && name == 'prototype') {
      throw FormatException(
        '@NAPI ${cls.name}: reserved ${static ? 'static' : 'instance'} member name "$name".',
      );
    }
    if (!names.add(name))
      throw FormatException(
        cls == null
            ? 'Duplicate JavaScript export: $name.'
            : 'Duplicate JavaScript member: ${cls.name}.$name.',
      );
  }

  void _members(
    ExportClass? cls,
    Iterable<Member> readable,
    Iterable<Member> writable,
    Set<String> names, {
    required bool static,
  }) {
    String context(String name) => cls == null ? name : '${cls.name}.$name';
    final getters = <Name, Member>{};
    final setters = <Name, Member>{
      for (final member in writable) member.name: member,
    };
    for (final member in readable) {
      if (cls?.isObject == true && member is Procedure && !member.isGetter) {
        throw FormatException(
          '@NAPI.object ${cls!.name}: only instance fields and getters can be exported as object properties: ${member.name.text}.',
        );
      }
      if (member is Procedure && member.kind == ProcedureKind.Method) {
        final name = _name(member, member.name.text);
        _memberName(cls, name, names, static: static);
        (static ? cls!.staticMethods : cls!.methods).add(
          _function(member, name, owner: cls),
        );
      } else if (member is Field || member is Procedure && member.isGetter) {
        if (member is Procedure) {
          _checkAsync(member.function, context(member.name.text));
        }
        getters[member.name] = member;
      } else if (_annotation(member) != null) {
        throw FormatException(
          'Unsupported annotated declaration: ${context(member.name.text)}.',
        );
      }
    }
    for (final key in {...getters.keys, ...setters.keys}) {
      final getter = getters[key];
      final setter = setters[key];
      final sourceName = (getter ?? setter)!.name.text;
      if (cls == null && setter is Procedure)
        _checkAsync(setter.function, sourceName);
      final readName = getter == null ? null : _rename(getter);
      final writeName = setter == null ? null : _rename(setter);
      if (readName != null && writeName != null && readName != writeName)
        throw FormatException(
          '@NAPI ${context(sourceName)}: getter and setter names must agree.',
        );
      final name = _checkName(readName ?? writeName ?? sourceName);
      _memberName(cls, name, names, static: static);
      final readType = getter == null
          ? null
          : _type(
              _substitution(cls, getter).substituteType(
                getter is Field
                    ? getter.type
                    : (getter as Procedure).function.returnType,
              ),
              '${context(name)}: return',
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
              '${context(name)}: parameter',
            );
      (cls == null
              ? module.properties
              : static
              ? cls.staticProperties
              : cls.properties)
          .add(
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
    if (type is TypeParameterType) {
      final parameter = _parameters[type.parameter];
      if (parameter == null) {
        throw FormatException(
          '@NAPI $context: unsupported type parameter ${type.parameter.name}.',
        );
      }
      final actual = _actual(type);
      return ExportType(
        actual,
        ValueKind.typeParameter,
        nullable: type.declaredNullability == Nullability.nullable,
        parameter: parameter,
        representation: _type(actual, context, result: result),
      );
    }
    if (type is DynamicType)
      return ExportType(_actual(type), ValueKind.dynamicValue);
    if (type is RecordType) {
      return ExportType(
        _actual(type),
        ValueKind.record,
        nullable: type.nullability == Nullability.nullable,
        recordFields: (
          positional: [
            for (var i = 0; i < type.positional.length; ++i)
              _type(type.positional[i], '$context: record field \$${i + 1}'),
          ],
          named: {
            for (final field in type.named)
              field.name: _type(
                field.type,
                '$context: record field ${field.name}',
              ),
          },
        ),
      );
    }
    if (type is FunctionType) {
      if (type.typeParameters.isNotEmpty) {
        throw FormatException(
          '@NAPI $context: generic function types are not supported yet.',
        );
      }
      return ExportType(
        _actual(type),
        ValueKind.function,
        nullable: type.nullability == Nullability.nullable,
        signature: ExportSignature(
          type:
              _actual(type.withDeclaredNullability(Nullability.nonNullable))
                  as FunctionType,
          positional: [
            for (var i = 0; i < type.positionalParameters.length; ++i)
              ExportParameter(
                name: 'arg$i',
                type: _type(
                  type.positionalParameters[i],
                  '$context: parameter $i',
                ),
                required: i < type.requiredParameterCount,
                defaultValue: null,
              ),
          ],
          named: [
            for (final parameter in type.namedParameters)
              ExportParameter(
                name: parameter.name,
                type: _type(
                  parameter.type,
                  '$context: parameter ${parameter.name}',
                ),
                required: parameter.isRequired,
                defaultValue: null,
              ),
          ],
          result: _type(type.returnType, '$context: return', result: true),
        ),
      );
    }
    if (type is NullType) return ExportType(_actual(type), ValueKind.nullValue);
    if (type is NeverType)
      return ExportType(
        _actual(type),
        type.nullability == Nullability.nullable
            ? ValueKind.nullValue
            : ValueKind.never,
      );
    if (result && type is VoidType)
      return ExportType(_actual(type), ValueKind.voidValue);
    if (type is InterfaceType) {
      final typeLibrary = type.classNode.enclosingLibrary;
      if (typeLibrary.importUri.toString() == 'package:napi/src/env.dart' ||
          typeLibrary.fileUri == annotationFile?.resolve('src/env.dart')) {
        if (type.classNode.name == 'JsUndefined') {
          return ExportType(
            _actual(type),
            ValueKind.undefined,
            nullable: type.nullability == Nullability.nullable,
          );
        }
        if (type.classNode.name == 'JsReference') {
          final inner = type.typeArguments.single;
          final kind =
              inner is InterfaceType &&
                  inner.nullability == Nullability.nonNullable &&
                  inner.classNode.enclosingLibrary == typeLibrary
              ? switch (inner.classNode.name) {
                  'JsObject' => JsReferenceKind.object,
                  'JsFunction' => JsReferenceKind.function,
                  'JsSymbol' => JsReferenceKind.symbol,
                  _ => null,
                }
              : null;
          if (kind == null) {
            throw FormatException(
              '@NAPI $context: JsReference requires non-nullable JsObject, JsFunction or JsSymbol.',
            );
          }
          return ExportType(
            _actual(type),
            ValueKind.jsReference,
            nullable: type.nullability == Nullability.nullable,
            referenceKind: kind,
          );
        }
        if (const {
          'JsObject',
          'JsFunction',
          'JsSymbol',
        }.contains(type.classNode.name)) {
          throw FormatException(
            '@NAPI $context: use JsReference<${type.classNode.name}> for JavaScript values in annotated APIs.',
          );
        }
      }
      final enumeration = enums[type.classNode];
      if (enumeration != null)
        return ExportType(
          _actual(type),
          ValueKind.enumeration,
          nullable: type.nullability == Nullability.nullable,
          enumExport: enumeration,
        );
      final exported = classes[type.classNode];
      if (exported != null) {
        final actual = _actual(type) as InterfaceType;
        if (actual.typeArguments.length !=
                exported.dartType.typeArguments.length ||
            !List.generate(
              actual.typeArguments.length,
              (i) =>
                  actual.typeArguments[i] == exported.dartType.typeArguments[i],
            ).every((same) => same)) {
          throw FormatException(
            '@NAPI $context: non-default generic class arguments are not supported: $type.',
          );
        }
        return ExportType(
          actual,
          ValueKind.object,
          nullable: type.nullability == Nullability.nullable,
          classExport: exported,
          typeArguments: [
            for (final argument in type.typeArguments)
              _type(argument, '$context: class argument'),
          ],
        );
      }
      final library = type.classNode.enclosingLibrary.importUri.toString();
      if (library == 'dart:async' &&
          (type.classNode.name == 'Future' ||
              type.classNode.name == 'Stream')) {
        return ExportType(
          _actual(type),
          type.classNode.name == 'Future' ? ValueKind.future : ValueKind.stream,
          nullable: type.nullability == Nullability.nullable,
          element: _type(
            type.typeArguments.single,
            '$context: ${type.classNode.name} value',
            result: true,
          ),
        );
      } else if (library == 'dart:core') {
        if (type.classNode.name == 'List') {
          return ExportType(
            _actual(type),
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
            _actual(type),
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
          'DateTime' => ValueKind.dateTime,
          'Object' => ValueKind.opaque,
          _ => null,
        };
        if (kind != null)
          return ExportType(
            _actual(type),
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
            _actual(type),
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
