import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/src/bounds_checks.dart' show calculateBounds;
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
  set,
  typedData,
  simd,
  simdList,
  dateTime,
  byteBuffer,
  byteData,
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

enum SimdKind { float32x4, int32x4, float64x2 }

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
    this.simdKind,
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
  final SimdKind? simdKind;
  final ExportSignature? signature;
  final ({List<ExportType> positional, Map<String, ExportType> named})?
  recordFields;
}

final class ExportTypeParameter {
  ExportTypeParameter(this.target, this.actualType, {this.reified = false});
  final TypeParameter target;
  final DartType actualType;
  final bool reified;
  DartType get invocationType => reified
      ? TypeParameterType(target, target.computeNullabilityFromBound())
      : actualType;
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
    this.envPositional = const [],
    this.envNamed = const [],
  });
  final Member target;
  final List<DartType> typeArguments;
  final FunctionType? tearOffType;
  final List<int> envPositional;
  final List<String> envNamed;
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
  ExportType? superclass;
  final specializations =
      <
        ExportClass,
        ({List<ExportFunction> methods, List<ExportProperty> properties})
      >{};
  final typeParameters = <ExportTypeParameter>[];
  ExportFunction? constructor;
  final methods = <ExportFunction>[];
  final properties = <ExportProperty>[];
  final staticMethods = <ExportFunction>[];
  final staticProperties = <ExportProperty>[];
  InterfaceType get dartType => InterfaceType(target, Nullability.nonNullable, [
    for (final parameter in typeParameters) parameter.invocationType,
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
      envClass = component.libraries
          .where(
            (library) =>
                library.importUri == _envUri ||
                library.fileUri == packages.resolve(_envUri),
          )
          .expand((library) => library.classes)
          .where((cls) => cls.name == 'Env')
          .firstOrNull,
      hierarchy = ClassHierarchy(component, CoreTypes(component));

  static final _annotationUri = Uri.parse('package:napi/napi.dart');
  static final _envUri = Uri.parse('package:napi/src/env.dart');
  final Uri? annotationFile;
  final Class? envClass;
  final ClassHierarchy hierarchy;
  final module = ExportModule();
  final classes = <Class, ExportClass>{};
  final enums = <Class, ExportEnum>{};
  final _parameters = <TypeParameter, ExportTypeParameter>{};
  static const _valuePreservingKinds = {
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
  };

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
          (declaration is! Class || declaration.isEnum)) {
        throw const FormatException('@NAPI.object can only annotate a class.');
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
        _typeParameters(
          cls.target.typeParameters,
          cls.name,
          reified: cls.isObject,
        ),
      );
      _parameters.clear();
    }
    final parents = <ExportClass, ExportClass>{};
    for (final cls in module.classes) {
      final ancestors = <Class>{};
      for (
        var ancestor = cls.target.superclass;
        ancestor != null;
        ancestor = ancestor.superclass
      ) {
        ancestors.add(ancestor);
        final parent = classes[ancestor];
        if (parent != null) parents.putIfAbsent(cls, () => parent);
      }
      for (final other in module.classes) {
        if (cls == other ||
            hierarchy.getClassAsInstanceOf(cls.target, other.target) == null) {
          continue;
        }
        if (cls.isObject || other.isObject) {
          throw FormatException(
            '@NAPI ${cls.name}: object mappings cannot participate in exported class inheritance: ${other.name}.',
          );
        }
        if (!ancestors.contains(other.target)) {
          throw FormatException(
            '@NAPI ${cls.name}: cannot implement an exported class without extending it: ${other.name}.',
          );
        }
      }
    }
    final ordered = <ExportClass>[];
    final visited = <ExportClass>{};
    void visit(ExportClass cls) {
      if (!visited.add(cls)) return;
      final parent = parents[cls];
      if (parent != null) visit(parent);
      ordered.add(cls);
    }

    for (final cls in module.classes) {
      visit(cls);
    }
    module.classes
      ..clear()
      ..addAll(ordered);
    for (final cls in module.classes) {
      _parameters.addAll({
        for (final parameter in cls.typeParameters) parameter.target: parameter,
      });
      final parent = parents[cls];
      if (parent != null) {
        final type = hierarchy.getClassAsInstanceOf(cls.target, parent.target)!;
        cls.superclass = ExportType(
          _actual(type.asInterfaceType),
          ValueKind.object,
          classExport: parent,
          typeArguments: [
            for (final argument in type.typeArguments)
              _type(argument, '${cls.name}: superclass argument'),
          ],
        );
      }
      if (cls.isObject) {
        _objectClass(cls);
      } else {
        _class(cls);
        for (
          var ancestor = parent;
          ancestor != null;
          ancestor = ancestor.superclass?.classExport
        ) {
          final type = hierarchy.getClassAsInstanceOf(
            cls.target,
            ancestor.target,
          )!;
          if (_actual(type.asInterfaceType) == ancestor.dartType) continue;
          cls.specializations[ancestor] = (
            methods: [
              for (final method in ancestor.methods)
                _function(method.target, method.name, owner: cls),
            ],
            properties: [
              for (final property in ancestor.properties)
                _property(cls, property.name, property.getter, property.setter),
            ],
          );
        }
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
    // VM lowering copies mixin members into application classes and records
    // their source mixin as the last implemented type.
    for (final member in exportedMembers.toList()) {
      var origin = member;
      while (origin.enclosingClass?.isEliminatedMixin == true) {
        final mixin = origin.enclosingClass!.implementedTypes.last.classNode;
        final Member? source = origin is Field
            ? mixin.fields
                  .where((field) => field.name == origin.name)
                  .firstOrNull
            : origin is Procedure
            ? mixin.procedures
                  .where(
                    (procedure) =>
                        procedure.name == origin.name &&
                        procedure.kind == (origin as Procedure).kind,
                  )
                  .firstOrNull
            : null;
        if (source == null || !exportedMembers.add(source)) break;
        origin = source;
      }
    }
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
    _checkGenericBounds();
    return module;
  }

  void _checkGenericBounds() {
    final requirements = {
      for (final cls in module.classes.where((cls) => cls.isObject))
        cls: <ExportTypeParameter>{},
    };
    var changed = false;
    void requireValue(ExportType type, ExportClass? owner, String context) {
      if (type.parameter case final parameter?) {
        if (owner?.isObject == true &&
            owner!.typeParameters.contains(parameter)) {
          if (requirements[owner]!.add(parameter)) changed = true;
          return;
        }
        requireValue(
          parameter.reified ? parameter.bound : type.representation!,
          owner,
          context,
        );
        return;
      }
      if (!_valuePreservingKinds.contains(type.kind)) {
        throw FormatException(
          '@NAPI $context: generic bounds must preserve JavaScript values: ${type.dartType}.',
        );
      }
    }

    void visit(ExportType type, ExportClass? owner, String context) {
      final signature = type.signature;
      if (signature != null) {
        for (final parameter in signature.typeParameters) {
          requireValue(parameter.bound, owner, context);
        }
        for (final parameter in [...signature.positional, ...signature.named]) {
          visit(parameter.type, owner, context);
        }
        visit(signature.result, owner, context);
      }
      final cls = type.classExport;
      if (cls?.isObject == true) {
        for (var i = 0; i < cls!.typeParameters.length; ++i) {
          if (requirements[cls]!.contains(cls.typeParameters[i])) {
            requireValue(type.typeArguments[i], owner, context);
          }
        }
      }
      for (final argument in type.typeArguments) {
        visit(argument, owner, context);
      }
      if (type.element != null) visit(type.element!, owner, context);
      if (type.recordFields case final fields?) {
        for (final field in [...fields.positional, ...fields.named.values]) {
          visit(field, owner, context);
        }
      }
    }

    void function(ExportFunction function, ExportClass? owner) {
      for (final parameter in [
        ...function.signature.positional,
        ...function.signature.named,
      ]) {
        visit(parameter.type, owner, '${function.name}: ${parameter.name}');
      }
      visit(function.signature.result, owner, '${function.name}: return');
    }

    void property(ExportProperty property, ExportClass? owner) {
      if (property.readType != null) {
        visit(property.readType!, owner, property.name);
      }
      if (property.writeType != null) {
        visit(property.writeType!, owner, property.name);
      }
    }

    do {
      changed = false;
      for (final cls in module.classes) {
        for (final member in [
          if (cls.constructor != null) cls.constructor!,
          ...cls.methods,
          ...cls.staticMethods,
          for (final view in cls.specializations.values) ...view.methods,
        ]) {
          function(member, cls);
        }
        for (final member in [
          ...cls.properties,
          ...cls.staticProperties,
          for (final view in cls.specializations.values) ...view.properties,
        ]) {
          property(member, cls);
        }
      }
    } while (changed);
    for (final member in module.functions) {
      function(member, null);
    }
    for (final member in module.properties) {
      property(member, null);
    }
    for (final member in module.constants) {
      visit(member.type, null, member.name);
    }
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

  DartType _actual(DartType type, {bool reified = true}) =>
      Substitution.fromMap({
        for (final entry in _parameters.entries)
          entry.key: reified
              ? entry.value.invocationType
              : entry.value.actualType,
      }).substituteType(type);

  List<ExportTypeParameter> _typeParameters(
    List<TypeParameter> parameters,
    String context, {
    Substitution substitution = Substitution.empty,
    bool reified = false,
  }) {
    final models = [
      for (final parameter in parameters)
        ExportTypeParameter(
          parameter,
          _actual(substitution.substituteType(parameter.defaultType)),
          reified: reified,
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
      if (!_valuePreservingKinds.contains(representation.kind)) {
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
      ExportParameter? parameter(FunctionParameter parameter, bool required) {
        final parameterName =
            constructor && owner!.isObject && parameter.isWildcard
            ? '_'
            : parameter is NamedParameter
            ? parameter.parameterName
            : parameter.cosmeticName ?? 'argument';
        final type = substitution.substituteType(parameter.type);
        if (type is InterfaceType && type.classNode == envClass) {
          if (!required || type.nullability != Nullability.nonNullable) {
            throw FormatException(
              '@NAPI $name: parameter $parameterName: injected Env must be required and non-nullable.',
            );
          }
          return null;
        }
        return ExportParameter(
          name: parameterName,
          type: _type(type, '$name: parameter $parameterName'),
          required: required,
          defaultValue: parameter.defaultValue,
        );
      }

      final positional = <ExportParameter>[];
      final named = <ExportParameter>[];
      final envPositional = <int>[];
      final envNamed = <String>[];
      for (var i = 0; i < function.positionalParameters.length; ++i) {
        final value = parameter(
          function.positionalParameters[i],
          i < function.requiredParameterCount,
        );
        if (value == null) {
          envPositional.add(i);
        } else {
          positional.add(value);
        }
      }
      for (final target in function.namedParameters) {
        final value = parameter(target, target.isRequired);
        if (value == null) {
          envNamed.add(target.parameterName);
        } else {
          named.add(value);
        }
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
                .map((parameter) => parameter.invocationType)
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
          positional: positional,
          named: named,
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
        envPositional: envPositional,
        envNamed: envNamed,
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
      throw const FormatException('@NAPI.object can only annotate a class.');
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
    final parent = cls.superclass?.classExport;
    if (parent == null) {
      _members(
        cls,
        hierarchy
            .getInterfaceMembers(cls.target)
            .where(
              (member) =>
                  member.enclosingClass != hierarchy.coreTypes.objectClass &&
                  _isExported(member),
            ),
        hierarchy
            .getInterfaceMembers(cls.target, setters: true)
            .where(
              (member) =>
                  _isExported(member) && !(member is Field && member.isFinal),
            ),
        <String>{},
        static: false,
      );
    } else {
      _inheritedMembers(cls, parent);
    }
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
    for (
      var ancestor = parent;
      ancestor != null;
      ancestor = ancestor.superclass?.classExport
    ) {
      final inherited = {
        ...ancestor.staticMethods.map((member) => member.name),
        ...ancestor.staticProperties.map((member) => member.name),
      };
      for (final name in staticNames.intersection(inherited)) {
        final method = cls.staticMethods
            .where((member) => member.name == name)
            .firstOrNull;
        final parentMethod = ancestor.staticMethods
            .where((member) => member.name == name)
            .firstOrNull;
        if (method != null &&
            parentMethod != null &&
            _sameStaticSignature(method, parentMethod)) {
          continue;
        }
        final property = cls.staticProperties
            .where((member) => member.name == name)
            .firstOrNull;
        final parentProperty = ancestor.staticProperties
            .where((member) => member.name == name)
            .firstOrNull;
        if (property != null &&
            parentProperty != null &&
            property.readType?.dartType == parentProperty.readType?.dartType &&
            property.writeType?.dartType ==
                parentProperty.writeType?.dartType) {
          continue;
        }
        throw FormatException(
          '@NAPI ${cls.name}: static export conflicts with inherited member: $name.',
        );
      }
    }
  }

  bool _sameStaticSignature(ExportFunction method, ExportFunction parent) {
    final signature = method.signature;
    final inherited = parent.signature;
    if (!_sameList(method.envPositional, parent.envPositional) ||
        !_sameList(method.envNamed, parent.envNamed) ||
        signature.positional.length != inherited.positional.length ||
        signature.named.length != inherited.named.length ||
        signature.typeParameters.length != inherited.typeParameters.length ||
        signature.typeParameters.isNotEmpty &&
            method.tearOffType != parent.tearOffType) {
      return false;
    }
    bool sameParameter(ExportParameter left, ExportParameter right) =>
        left.required == right.required &&
        left.type.dartType == right.type.dartType;
    for (var i = 0; i < signature.positional.length; ++i) {
      if (!sameParameter(signature.positional[i], inherited.positional[i]))
        return false;
    }
    for (var i = 0; i < signature.named.length; ++i) {
      if (signature.named[i].name != inherited.named[i].name ||
          !sameParameter(signature.named[i], inherited.named[i]))
        return false;
    }
    for (var i = 0; i < signature.typeParameters.length; ++i) {
      if (signature.typeParameters[i].bound.dartType !=
          inherited.typeParameters[i].bound.dartType) {
        return false;
      }
    }
    final result = signature.result.dartType;
    final parentResult = inherited.result.dartType;
    if (result == parentResult) return true;
    if (signature.result.kind != ValueKind.object ||
        inherited.result.kind != ValueKind.object ||
        result is! InterfaceType ||
        parentResult is! InterfaceType ||
        result.nullability != parentResult.nullability) {
      return false;
    }
    final ancestor = hierarchy.getClassAsInstanceOf(
      result.classNode,
      parentResult.classNode,
    );
    return ancestor != null &&
        Substitution.fromInterfaceType(
              result,
            ).substituteType(ancestor.asInterfaceType) ==
            parentResult;
  }

  bool _sameList<T>(List<T> left, List<T> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; ++index) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  void _inheritedMembers(ExportClass cls, ExportClass parent) {
    final methods = {
      for (final member in parent.methods)
        member.name: _function(member.target, member.name, owner: cls),
    };
    final properties = {
      for (final member in parent.properties)
        member.name: _property(cls, member.name, member.getter, member.setter),
    };
    final layers = <Class>[];
    for (
      var target = cls.target;
      target != parent.target;
      target = target.superclass!
    ) {
      layers.add(target);
    }
    for (final layer in layers.reversed) {
      _members(
        cls,
        [
          ...layer.fields.where((member) => member.isInstanceMember),
          ...layer.procedures.where(
            (member) => member.isInstanceMember && !member.isSetter,
          ),
        ].where(_isExported),
        [
          ...layer.fields.where(
            (member) =>
                member.isInstanceMember && member.hasSetter && !member.isFinal,
          ),
          ...layer.procedures.where(
            (member) => member.isInstanceMember && member.isSetter,
          ),
        ].where(_isExported),
        <String>{},
        static: false,
      );
      for (final method in cls.methods) {
        final previous = methods[method.name];
        if (properties.containsKey(method.name) ||
            previous != null && previous.target.name != method.target.name) {
          throw FormatException(
            '@NAPI ${cls.name}: inherited JavaScript member conflicts with ${method.name}.',
          );
        }
        methods[method.name] = method;
      }
      for (final property in cls.properties) {
        final previous = properties[property.name];
        final target = (property.getter ?? property.setter)!;
        if (methods.containsKey(property.name) ||
            previous != null &&
                (previous.getter ?? previous.setter)!.name != target.name) {
          throw FormatException(
            '@NAPI ${cls.name}: inherited JavaScript member conflicts with ${property.name}.',
          );
        }
        properties[property.name] = _property(
          cls,
          property.name,
          property.getter ?? previous?.getter,
          property.setter ?? previous?.setter,
        );
      }
      cls.methods.clear();
      cls.properties.clear();
    }
    cls.methods.addAll(methods.values);
    cls.properties.addAll(properties.values);
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
      (cls == null
              ? module.properties
              : static
              ? cls.staticProperties
              : cls.properties)
          .add(_property(cls, name, getter, setter));
    }
  }

  ExportProperty _property(
    ExportClass? cls,
    String name,
    Member? getter,
    Member? setter,
  ) {
    final context = cls == null ? name : '${cls.name}.$name';
    return ExportProperty(
      name: name,
      owner: cls,
      getter: getter,
      setter: setter,
      readType: getter == null
          ? null
          : _type(
              _substitution(cls, getter).substituteType(
                getter is Field
                    ? getter.type
                    : (getter as Procedure).function.returnType,
              ),
              '$context: return',
              result: true,
            ),
      writeType: setter == null
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
              '$context: parameter',
            ),
    );
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
        representation: _type(
          _actual(type, reified: false),
          context,
          result: result,
        ),
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
      final savedParameters = Map<TypeParameter, ExportTypeParameter>.of(
        _parameters,
      );
      try {
        final signatureType =
            _actual(type.withDeclaredNullability(Nullability.nonNullable))
                as FunctionType;
        final fresh = getFreshTypeParametersFromStructuralParameters(
          type.typeParameters,
        );
        // Structural parameters can retain `dynamic` defaults after lowering.
        final objectClass = hierarchy.coreTypes.objectClass;
        for (final parameter in fresh.freshTypeParameters) {
          final bound = parameter.bound;
          if (bound is InterfaceType &&
              bound.classNode == objectClass &&
              bound.nullability == Nullability.nonNullable) {
            parameter.defaultType = bound;
          }
        }
        final defaults = calculateBounds(
          fresh.freshTypeParameters,
          objectClass,
        );
        for (var i = 0; i < defaults.length; ++i) {
          fresh.freshTypeParameters[i].defaultType = defaults[i];
        }
        final body =
            fresh.substitute(type.withoutTypeParameters) as FunctionType;
        final parameters = _typeParameters(
          fresh.freshTypeParameters,
          context,
          reified: true,
        );
        return ExportType(
          _actual(type),
          ValueKind.function,
          nullable: type.nullability == Nullability.nullable,
          signature: ExportSignature(
            type: signatureType,
            typeParameters: parameters,
            positional: [
              for (var i = 0; i < body.positionalParameters.length; ++i)
                ExportParameter(
                  name: 'arg$i',
                  type: _type(
                    body.positionalParameters[i],
                    '$context: parameter $i',
                  ),
                  required: i < body.requiredParameterCount,
                  defaultValue: null,
                ),
            ],
            named: [
              for (final parameter in body.namedParameters)
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
            result: _type(body.returnType, '$context: return', result: true),
          ),
        );
      } finally {
        _parameters
          ..clear()
          ..addAll(savedParameters);
      }
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
      if (type.classNode == envClass) {
        throw FormatException(
          '@NAPI $context: Env is only supported as an injected required non-nullable parameter of an annotated function, method or constructor.',
        );
      }
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
        if (!exported.isObject &&
            (actual.typeArguments.length !=
                    exported.dartType.typeArguments.length ||
                !List.generate(
                  actual.typeArguments.length,
                  (i) =>
                      actual.typeArguments[i] ==
                      exported.dartType.typeArguments[i],
                ).every((same) => same))) {
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
        if (type.classNode.name == 'Set') {
          return ExportType(
            _actual(type),
            ValueKind.set,
            nullable: type.nullability == Nullability.nullable,
            element: _type(type.typeArguments.single, '$context: Set element'),
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
        final simd = switch (type.classNode.name) {
          'Float32x4' || 'Float32x4List' => SimdKind.float32x4,
          'Int32x4' || 'Int32x4List' => SimdKind.int32x4,
          'Float64x2' || 'Float64x2List' => SimdKind.float64x2,
          _ => null,
        };
        if (simd != null) {
          return ExportType(
            _actual(type),
            type.classNode.name.endsWith('List')
                ? ValueKind.simdList
                : ValueKind.simd,
            nullable: type.nullability == Nullability.nullable,
            simdKind: simd,
          );
        }
        if (type.classNode.name == 'ByteBuffer' ||
            type.classNode.name == 'ByteData') {
          return ExportType(
            _actual(type),
            type.classNode.name == 'ByteBuffer'
                ? ValueKind.byteBuffer
                : ValueKind.byteData,
            nullable: type.nullability == Nullability.nullable,
          );
        }
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
