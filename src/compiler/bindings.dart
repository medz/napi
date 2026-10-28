import 'package:kernel/ast.dart';
import 'package:kernel/type_algebra.dart';

import 'calls.dart';
import 'exports.dart';

Procedure generateRegister(
  Component component,
  Library library,
  Library envLibrary,
  ExportModule exports,
) {
  final calls = Calls(component, library, envLibrary);
  final env = PositionalParameter(cosmeticName: 'env', type: calls.envType);
  final target = PositionalParameter(
    cosmeticName: 'exports',
    type: calls.objectType,
  );
  final statements = <Statement>[];
  void define(String name, Expression value, {bool readOnly = false}) =>
      statements.add(
        ExpressionStatement(
          calls.call(
            VariableGet(target),
            calls.method(
              calls.objectClass,
              readOnly ? '_defineValue' : 'defineValue',
            ),
            [StringLiteral(name), value],
            named: [if (readOnly) NamedExpression('attributes', IntLiteral(2))],
          ),
        ),
      );

  Expression callbacks(
    FunctionType signature,
    String parameter,
    List<MapEntry<String, Procedure>> entries,
  ) {
    final mapType =
        signature.namedParameters.singleWhere((p) => p.name == parameter).type
            as InterfaceType;
    return MapLiteral(
      [
        for (final entry in entries)
          MapLiteralEntry(
            StringLiteral(entry.key),
            calls.bind(entry.value, env),
          ),
      ],
      keyType: mapType.typeArguments[0],
      valueType: mapType.typeArguments[1],
    );
  }

  for (final enumeration in exports.enums) {
    final object = calls.local(
      statements,
      enumeration.name,
      calls.objectType,
      calls.call(VariableGet(env), calls.method(calls.envClass, 'object'), []),
    );
    for (final value in enumeration.cases) {
      statements.add(
        ExpressionStatement(
          calls.call(
            VariableGet(object),
            calls.method(calls.objectClass, '_defineValue'),
            [StringLiteral(value.name), IntLiteral(value.index)],
            named: [
              // Node-API napi_enumerable; cases are not writable/configurable.
              NamedExpression('attributes', IntLiteral(2)),
            ],
          ),
        ),
      );
    }
    define(enumeration.name, VariableGet(object));
  }
  for (final cls in exports.classes.where((cls) => !cls.isObject)) {
    final signature = FunctionTypeInstantiator.instantiate(
      calls
          .method(calls.envClass, 'defineClass')
          .function
          .computeFunctionType(Nullability.nonNullable),
      [cls.dartType],
    );
    final Expression constructor;
    if (cls.constructor case final function?) {
      constructor = calls.bind(calls.function(function, rawResult: true), env);
    } else {
      constructor = FunctionExpression(
        FunctionNode(
          ExpressionStatement(
            calls.failure('${cls.name} has no public unnamed constructor.'),
          ),
          positionalParameters: [
            PositionalParameter(
              cosmeticName: 'arguments',
              type: calls.argumentsType,
            ),
          ],
          returnType: cls.dartType,
        ),
      );
    }
    define(
      cls.name,
      calls.call(
        VariableGet(env),
        calls.method(calls.envClass, 'defineClass'),
        [StringLiteral(cls.name)],
        types: [cls.dartType],
        named: [
          NamedExpression('constructor', constructor),
          NamedExpression(
            'methods',
            callbacks(signature, 'methods', [
              for (final function in cls.methods)
                MapEntry(function.name, calls.function(function)),
            ]),
          ),
          NamedExpression(
            'getters',
            callbacks(signature, 'getters', [
              for (final property in cls.properties)
                if (property.getter != null)
                  MapEntry(
                    property.name,
                    calls.property(property, setter: false),
                  ),
            ]),
          ),
          NamedExpression(
            'setters',
            callbacks(signature, 'setters', [
              for (final property in cls.properties)
                if (property.setter != null)
                  MapEntry(
                    property.name,
                    calls.property(property, setter: true),
                  ),
            ]),
          ),
          NamedExpression(
            'staticMethods',
            callbacks(signature, 'staticMethods', [
              for (final function in cls.staticMethods)
                MapEntry(function.name, calls.function(function)),
            ]),
          ),
          NamedExpression(
            'staticGetters',
            callbacks(signature, 'staticGetters', [
              for (final property in cls.staticProperties)
                if (property.getter != null)
                  MapEntry(
                    property.name,
                    calls.property(property, setter: false),
                  ),
            ]),
          ),
          NamedExpression(
            'staticSetters',
            callbacks(signature, 'staticSetters', [
              for (final property in cls.staticProperties)
                if (property.setter != null)
                  MapEntry(
                    property.name,
                    calls.property(property, setter: true),
                  ),
            ]),
          ),
        ],
      ),
    );
  }
  final classRegistrationEnd = statements.length;
  for (final cls in exports.classes) {
    for (final instance in [
      if (cls.instances.isNotEmpty) cls,
      ...cls.instances,
    ]) {
      for (final (contract, members) in [
        (cls, (methods: instance.methods, properties: instance.properties)),
        for (final entry in instance.specializations.entries)
          (entry.key, entry.value),
      ]) {
        final signature = FunctionTypeInstantiator.instantiate(
          calls
              .method(calls.envClass, '_specializeClassInstance')
              .function
              .computeFunctionType(Nullability.nonNullable),
          [instance.dartType, contract.dartType],
        );
        statements.add(
          ExpressionStatement(
            calls.call(
              VariableGet(env),
              calls.method(calls.envClass, '_specializeClassInstance'),
              [],
              types: [instance.dartType, contract.dartType],
              named: [
                NamedExpression('registerType', BoolLiteral(contract == cls)),
                NamedExpression(
                  'methods',
                  callbacks(signature, 'methods', [
                    for (final method in members.methods)
                      MapEntry(method.name, calls.function(method)),
                  ]),
                ),
                NamedExpression(
                  'getters',
                  callbacks(signature, 'getters', [
                    for (final property in members.properties)
                      if (property.getter != null)
                        MapEntry(
                          property.name,
                          calls.property(property, setter: false),
                        ),
                  ]),
                ),
                NamedExpression(
                  'setters',
                  callbacks(signature, 'setters', [
                    for (final property in members.properties)
                      if (property.setter != null)
                        MapEntry(
                          property.name,
                          calls.property(property, setter: true),
                        ),
                  ]),
                ),
              ],
            ),
          ),
        );
      }
    }
  }
  for (final cls in exports.classes) {
    final parent = cls.superclass?.classExport;
    if (parent == null) continue;
    statements.add(
      ExpressionStatement(
        calls.call(
          VariableGet(env),
          calls.method(calls.envClass, '_inheritClass'),
          [],
          types: [cls.dartType, parent.dartType],
        ),
      ),
    );
  }
  for (final cls in exports.classes) {
    for (final entry in cls.specializations.entries) {
      final signature = FunctionTypeInstantiator.instantiate(
        calls
            .method(calls.envClass, '_specializeClass')
            .function
            .computeFunctionType(Nullability.nonNullable),
        [cls.dartType, entry.key.dartType],
      );
      statements.add(
        ExpressionStatement(
          calls.call(
            VariableGet(env),
            calls.method(calls.envClass, '_specializeClass'),
            [],
            types: [cls.dartType, entry.key.dartType],
            named: [
              NamedExpression(
                'methods',
                callbacks(signature, 'methods', [
                  for (final function in entry.value.methods)
                    MapEntry(function.name, calls.function(function)),
                ]),
              ),
              NamedExpression(
                'getters',
                callbacks(signature, 'getters', [
                  for (final property in entry.value.properties)
                    if (property.getter != null)
                      MapEntry(
                        property.name,
                        calls.property(property, setter: false),
                      ),
                ]),
              ),
              NamedExpression(
                'setters',
                callbacks(signature, 'setters', [
                  for (final property in entry.value.properties)
                    if (property.setter != null)
                      MapEntry(
                        property.name,
                        calls.property(property, setter: true),
                      ),
                ]),
              ),
            ],
          ),
        ),
      );
    }
  }
  for (final function in exports.functions) {
    define(
      function.name,
      calls.call(VariableGet(env), calls.method(calls.envClass, 'function'), [
        StringLiteral(function.name),
        calls.bind(calls.function(function), env),
      ]),
    );
  }
  for (final value in exports.constants) {
    define(value.name, calls.constant(value, env), readOnly: true);
  }
  for (final property in exports.properties) {
    statements.add(
      ExpressionStatement(
        calls.call(
          VariableGet(env),
          calls.method(calls.envClass, '_defineProperty'),
          [VariableGet(target), StringLiteral(property.name)],
          named: [
            if (property.getter != null)
              NamedExpression(
                'getter',
                calls.bind(calls.property(property, setter: false), env),
              ),
            if (property.setter != null)
              NamedExpression(
                'setter',
                calls.bind(calls.property(property, setter: true), env),
              ),
          ],
        ),
      ),
    );
  }
  if (calls.usesClassBounds) {
    statements.insertAll(classRegistrationEnd, [
      for (final cls in exports.classes.where((cls) => !cls.isObject))
        for (final instance in [cls, ...cls.instances])
          ExpressionStatement(
            calls.call(
              VariableGet(env),
              calls.method(calls.envClass, '_registerClassBound'),
              [],
              types: [instance.dartType],
            ),
          ),
    ]);
  }
  return calls.procedure(
    '_napiRegister',
    [env, target],
    const VoidType(),
    Block(statements),
  );
}
